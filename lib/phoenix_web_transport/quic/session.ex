defmodule PhoenixWebTransport.Quic.Session do
  @moduledoc """
  One WebTransport session on erlang_quic, driving a `Phoenix.Socket.Transport`.

  The process is the HTTP/3 connection's owner, so it receives the extended
  CONNECT request, the claimed WebTransport streams, and the CONNECT stream's
  capsules. It is also the Phoenix transport pid, so channel pushes arrive
  here as messages and go out on QUIC streams, one per lane, with RFC 9218
  urgency set from the frame size.

  Wire format is identical to the cowboy session
  (`PhoenixWebTransport.Handler`): the client sends frames on one bidi
  stream, the server opens one uni stream per lane starting with
  `<<lane::32>>`. The browser class does not know which server it talks to.
  """

  use GenServer

  require Logger

  alias PhoenixWebTransport.{Frame, Lanes}

  @wt_stream 0x54
  @capsule_close_session 0x2843
  @capsule_drain_session 0x78AE

  defstruct qc: nil,
            h3: nil,
            endpoint: nil,
            socket: nil,
            opts: [],
            socket_state: nil,
            session_id: nil,
            in_buf: %{},
            lanes: %{},
            max_lanes: 16,
            closing: false

  @doc "Builds the per-session option set from the listener options."
  def options(opts) do
    [
      endpoint: Keyword.fetch!(opts, :endpoint),
      socket: Keyword.fetch!(opts, :socket),
      path: Keyword.get(opts, :path, "/live"),
      max_lanes: Keyword.get(opts, :max_lanes, 16),
      socket_opts: [
        serializer: [{PhoenixWebTransport.LaneSerializer, "~> 2.0.0"}],
        check_origin: Keyword.get(opts, :check_origin, false)
      ]
    ]
  end

  def start(quic_conn, opts), do: GenServer.start(__MODULE__, {quic_conn, opts})

  @impl true
  def init({qc, opts}) do
    {:ok,
     %__MODULE__{
       qc: qc,
       endpoint: Keyword.fetch!(opts, :endpoint),
       socket: Keyword.fetch!(opts, :socket),
       opts: opts,
       max_lanes: Keyword.fetch!(opts, :max_lanes)
     }}
  end

  # -- HTTP/3 events ---------------------------------------------------------

  @impl true
  def handle_info({:quic_h3, h3, :connected}, state), do: {:noreply, %{state | h3: h3}}

  def handle_info(
        {:quic_h3, h3, {:request, sid, "CONNECT", path, headers}},
        %{session_id: nil} = state
      ) do
    state = %{state | h3: h3}

    with :ok <- check_protocol(headers),
         :ok <- check_origin(headers, state.opts[:socket_opts]),
         {:ok, socket_state} <- connect(state, path, headers) do
      :ok = :quic_h3.send_response(h3, sid, 200, [])
      {:ok, socket_state} = state.socket.init(socket_state)
      state = %{state | session_id: sid, socket_state: socket_state}
      {:noreply, ensure_lane(state, Lanes.control())}
    else
      {:error, status, reason} ->
        Logger.info("webtransport connect refused: #{inspect(reason)}")
        :quic_h3.respond(h3, sid, status, [], <<>>)
        {:noreply, state}
    end
  end

  def handle_info({:quic_h3, h3, {:request, sid, _method, _path, _headers}}, state) do
    :quic_h3.respond(h3, sid, 404, [], <<>>)
    {:noreply, %{state | h3: h3}}
  end

  # Claimed WebTransport streams from the client: the first varint is the
  # session id, then our frames.
  def handle_info({:quic_h3, _h3, {:stream_type_open, _dir, stream_id, _type}}, state) do
    {:noreply, put_in(state.in_buf[stream_id], {:header, <<>>})}
  end

  def handle_info({:quic_h3, _h3, {:stream_type_data, _dir, stream_id, data, _fin}}, state) do
    case Map.get(state.in_buf, stream_id, {:header, <<>>}) do
      {:header, buf} -> strip_session_id(state, stream_id, buf <> data)
      {:frames, buf} -> consume_frames(state, stream_id, buf <> data)
    end
  end

  def handle_info({:quic_h3, _h3, {event, _dir, stream_id}}, state)
      when event in [:stream_type_closed] do
    {:noreply, %{state | in_buf: Map.delete(state.in_buf, stream_id)}}
  end

  def handle_info({:quic_h3, _h3, {event, _dir, _stream_id, _code}}, state)
      when event in [:stream_type_reset, :stream_type_stop_sending] do
    {:noreply, state}
  end

  # Capsules on the CONNECT stream: CLOSE_WEBTRANSPORT_SESSION or DRAIN
  # end the session; fin on the stream does too.
  def handle_info({:quic_h3, _h3, {:data, sid, data, fin}}, %{session_id: sid} = state) do
    if fin or session_close_capsule?(data),
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_info({:quic_h3, _h3, :closed}, state), do: {:stop, :normal, state}
  def handle_info({:quic_h3, _h3, {:closed, _reason}}, state), do: {:stop, :normal, state}
  def handle_info({:quic_h3, _h3, _other}, state), do: {:noreply, state}

  # -- Phoenix socket messages -----------------------------------------------

  def handle_info(message, %{socket_state: socket_state} = state) when socket_state != nil do
    case state.socket.handle_info(message, socket_state) do
      {:ok, socket_state} ->
        {:noreply, %{state | socket_state: socket_state}}

      {:push, push, socket_state} ->
        {:noreply, push_out(%{state | socket_state: socket_state}, push)}

      {:stop, _reason, socket_state} ->
        {:stop, :normal, %{state | socket_state: socket_state}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket_state: nil}), do: :ok

  def terminate(_reason, %{socket: socket, socket_state: socket_state} = state) do
    socket.terminate(:closed, socket_state)
    if state.session_id, do: :quic.safe_close(state.qc)
    :ok
  end

  # -- connect ---------------------------------------------------------------

  defp check_protocol(headers) do
    case List.keyfind(headers, ":protocol", 0) do
      {_, "webtransport"} -> :ok
      nil -> :ok
      other -> {:error, 400, {:protocol, other}}
    end
  end

  defp check_origin(headers, socket_opts) do
    case Keyword.get(socket_opts, :check_origin, false) do
      false ->
        :ok

      allowed when is_list(allowed) ->
        case List.keyfind(headers, "origin", 0) do
          {_, origin} ->
            if origin in allowed, do: :ok, else: {:error, 403, {:origin_not_allowed, origin}}

          nil ->
            {:error, 403, :origin_missing}
        end
    end
  end

  defp connect(state, path, headers) do
    %URI{query: query} = URI.parse(path)

    config = %{
      endpoint: state.endpoint,
      transport: :webtransport,
      options: state.opts[:socket_opts],
      params: URI.decode_query(query || ""),
      connect_info: %{
        peer_data: peer_data(state.qc),
        uri: %URI{scheme: "https", host: header(headers, ":authority"), path: path}
      }
    }

    case state.socket.connect(config) do
      {:ok, socket_state} -> {:ok, socket_state}
      :error -> {:error, 403, :socket_refused}
      {:error, reason} -> {:error, 403, reason}
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp peer_data(qc) do
    case :quic.peername(qc) do
      {:ok, {address, port}} -> %{address: address, port: port, ssl_cert: nil}
      _ -> nil
    end
  end

  # -- inbound ---------------------------------------------------------------

  defp strip_session_id(state, stream_id, buf) do
    case varint(buf) do
      {:ok, _session_id, rest} -> consume_frames(state, stream_id, rest)
      :more -> {:noreply, put_in(state.in_buf[stream_id], {:header, buf})}
    end
  end

  defp consume_frames(state, stream_id, buf) do
    {frames, rest} = Frame.decode(buf)
    state = put_in(state.in_buf[stream_id], {:frames, rest})

    Enum.reduce_while(frames, {:noreply, state}, fn {type, payload}, {:noreply, st} ->
      case st.socket.handle_in({payload, opcode: type}, st.socket_state) do
        {:ok, socket_state} ->
          {:cont, {:noreply, %{st | socket_state: socket_state}}}

        {:reply, _status, push, socket_state} ->
          {:cont, {:noreply, push_out(%{st | socket_state: socket_state}, push)}}

        {:stop, _reason, socket_state} ->
          {:halt, {:stop, :normal, %{st | socket_state: socket_state}}}
      end
    end)
  end

  defp varint(<<0::2, v::6, rest::binary>>), do: {:ok, v, rest}
  defp varint(<<1::2, v::14, rest::binary>>), do: {:ok, v, rest}
  defp varint(<<2::2, v::30, rest::binary>>), do: {:ok, v, rest}
  defp varint(<<3::2, v::62, rest::binary>>), do: {:ok, v, rest}
  defp varint(_), do: :more

  defp session_close_capsule?(data) do
    case varint(data) do
      {:ok, type, _} -> type in [@capsule_close_session, @capsule_drain_session]
      :more -> false
    end
  end

  # -- outbound --------------------------------------------------------------

  defp push_out(%{closing: true} = state, _push), do: state

  defp push_out(state, push) do
    push
    |> Lanes.frames_for_push()
    |> Enum.reduce(state, fn {lane, frame}, st -> send_lane(st, lane, frame) end)
  end

  defp send_lane(state, lane, {type, payload}) do
    slot = Lanes.slot_for(lane, state.max_lanes)
    state = ensure_lane(state, slot)
    stream_id = Map.fetch!(state.lanes, slot)
    size = byte_size(payload)

    case :quic.set_stream_priority(state.qc, stream_id, Lanes.urgency(size), true) do
      :ok -> :ok
      error -> Logger.warning("webtransport lane #{slot}: priority #{inspect(error)}")
    end

    case :quic.send_data(
           state.qc,
           stream_id,
           IO.iodata_to_binary(Frame.encode(type, payload)),
           false
         ) do
      :ok ->
        state

      {:error, reason} ->
        Logger.info("webtransport lane #{slot}: send failed (#{inspect(reason)}), ending session")
        send(self(), {:quic_h3, state.h3, :closed})
        %{state | closing: true}
    end
  end

  # Server-initiated uni stream: WT_STREAM type, session id, then our lane id.
  defp ensure_lane(state, slot) do
    case Map.fetch(state.lanes, slot) do
      {:ok, _} ->
        state

      :error ->
        {:ok, stream_id} = :quic.open_unidirectional_stream(state.qc)

        header =
          :quic_varint.encode(@wt_stream) <> :quic_varint.encode(state.session_id) <> <<slot::32>>

        :ok = :quic.send_data(state.qc, stream_id, header, false)
        %{state | lanes: Map.put(state.lanes, slot, stream_id)}
    end
  end
end
