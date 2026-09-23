defmodule PhoenixWebTransport.Handler do
  @moduledoc """
  A `cowboy_webtransport` handler that drives a `Phoenix.Socket.Transport`
  (such as `Phoenix.LiveView.Socket`) over a WebTransport session.

  This is the WebTransport equivalent of `Phoenix.Transports.WebSocket`:
  it performs the connect handshake, then owns the session process and
  forwards every client frame to `handle_in/2` and every Erlang message to
  `handle_info/2`, exactly as the WebSocket transport does. No Phoenix or
  LiveView code is patched.

  ## Streams

    * The client opens one bidirectional stream and sends all of its
      messages (joins, events, heartbeats) on it, length-prefixed
      (`PhoenixWebTransport.Frame`).
    * The server opens one unidirectional stream per *lane*. Lane 0 is the
      control lane. `PhoenixWebTransport.LaneSerializer` assigns component
      diffs to lane `cid`, and this handler maps lanes onto a bounded set of
      streams (`:max_lanes`), so a page with many components shares streams
      while a page with few gets one stream per component.
    * Each server stream begins with `<<lane::32>>` and then carries frames.

  ## Priority

  QUIC streams are independent, but the sender still has to choose which
  stream's bytes go into the next packet. msquic schedules FIFO across
  streams of equal priority, so a small frame queued behind a large one
  would still wait. Before each send the handler sets the stream's priority
  from the size of the frame it is about to write, which is a
  shortest-message-first policy in the spirit of Homa's SRPT scheduling.

  Two ways to set it, chosen by the `:stream_priority` option:

    * `:peek` (default) reads the quicer stream handle out of the connection
      process's dictionary, a cowboy implementation detail. Works with
      unpatched cowboy 2.19.
    * `:command` emits `{set_stream_priority, StreamID, Prio}`, which needs
      `patches/0001-cowboy-webtransport-set-stream-priority.patch`.
  """

  @behaviour :cowboy_webtransport

  require Logger

  alias PhoenixWebTransport.Frame

  @control 0
  @default_max_lanes 16
  @max_priority 0xFFFF

  defmodule State do
    @moduledoc false
    defstruct socket: nil,
              socket_state: nil,
              conn_pid: nil,
              max_lanes: 16,
              lanes: %{},
              refs: %{},
              in_buf: %{},
              closing: false,
              priority_via: :peek
  end

  # -- cowboy_handler --------------------------------------------------------

  @impl true
  def init(req, {endpoint, socket, opts}) do
    params = URI.decode_query(Map.get(req, :qs, ""))

    with :ok <- check_origin(req, opts),
         {:ok, socket_state} <- connect(endpoint, socket, opts, params, req) do
      state = %State{
        socket: socket,
        socket_state: socket_state,
        conn_pid: req.pid,
        max_lanes: Keyword.get(opts, :max_lanes, @default_max_lanes),
        priority_via: Keyword.get(opts, :stream_priority, :peek)
      }

      {:cowboy_webtransport, req, state}
    else
      {:error, status, reason} ->
        Logger.info("webtransport connect refused: #{inspect(reason)}")
        {:ok, :cowboy_req.reply(status, req), nil}
    end
  end

  defp connect(endpoint, socket, opts, params, req) do
    config = %{
      endpoint: endpoint,
      transport: :webtransport,
      options: opts,
      params: params,
      connect_info: connect_info(req)
    }

    case socket.connect(config) do
      {:ok, socket_state} -> {:ok, socket_state}
      :error -> {:error, 403, :socket_refused}
      {:error, reason} -> {:error, 403, reason}
    end
  end

  # WebTransport CONNECT requests are sent with credentials mode "omit", so
  # there is no cookie and therefore no Plug session here. Apps that need
  # identity on connect pass a signed token in the params instead.
  defp connect_info(req) do
    %{
      peer_data: peer_data(Map.get(req, :peer)),
      uri: %URI{
        scheme: "https",
        host: Map.get(req, :host),
        port: Map.get(req, :port),
        path: Map.get(req, :path),
        query: Map.get(req, :qs)
      }
    }
  end

  defp peer_data({address, port}), do: %{address: address, port: port, ssl_cert: nil}
  defp peer_data(_), do: nil

  defp check_origin(req, opts) do
    case Keyword.get(opts, :check_origin, false) do
      false ->
        :ok

      allowed when is_list(allowed) ->
        origin = :cowboy_req.header("origin", req)
        if origin in allowed, do: :ok, else: {:error, 403, {:origin_not_allowed, origin}}
    end
  end

  # -- cowboy_webtransport ---------------------------------------------------

  @impl true
  def webtransport_init(%State{socket: socket} = state) do
    {:ok, socket_state} = socket.init(state.socket_state)
    {cmds, state} = ensure_lane(%{state | socket_state: socket_state}, @control)
    {cmds, state}
  end

  @impl true
  def webtransport_handle({:stream_open, stream_id, _type}, state) do
    {[], put_in(state.in_buf[stream_id], <<>>)}
  end

  def webtransport_handle({:opened_stream_id, {:lane, slot}, stream_id}, state) do
    {:opening, pending} = Map.fetch!(state.lanes, slot)
    state = %{state | lanes: Map.put(state.lanes, slot, {:open, stream_id})}
    state = remember_ref(state, slot, stream_id)

    {cmds, state} =
      Enum.reduce(pending, {[], state}, fn frame, {acc, st} ->
        {c, st} = send_frame(st, slot, frame)
        {acc ++ c, st}
      end)

    {cmds, state}
  end

  def webtransport_handle({:stream_data, stream_id, _fin, data}, state) do
    buffer = Map.get(state.in_buf, stream_id, <<>>) <> data
    {frames, rest} = Frame.decode(buffer)
    state = put_in(state.in_buf[stream_id], rest)

    Enum.reduce_while(frames, {[], state}, fn {type, payload}, {cmds, st} ->
      case st.socket.handle_in({payload, opcode: type}, st.socket_state) do
        {:ok, socket_state} ->
          {:cont, {cmds, %{st | socket_state: socket_state}}}

        {:reply, _status, push, socket_state} ->
          {more, st} = push_out(%{st | socket_state: socket_state}, push)
          {:cont, {cmds ++ more, st}}

        {:stop, _reason, socket_state} ->
          {:halt, {cmds ++ [{:close, 0}], %{st | socket_state: socket_state}}}
      end
    end)
  end

  def webtransport_handle({:datagram, _data}, state), do: {[], state}
  def webtransport_handle(:close_initiated, state), do: {[], state}
  def webtransport_handle(_event, state), do: {[], state}

  @impl true
  def webtransport_info(message, %State{socket: socket} = state) do
    case socket.handle_info(message, state.socket_state) do
      {:ok, socket_state} ->
        {[], %{state | socket_state: socket_state}}

      {:push, push, socket_state} ->
        push_out(%{state | socket_state: socket_state}, push)

      {:stop, _reason, socket_state} ->
        {[{:close, 0}], %{state | socket_state: socket_state}}
    end
  end

  @impl true
  def terminate(reason, _req, %State{socket: socket, socket_state: socket_state})
      when socket_state != nil do
    socket.terminate(normalize_reason(reason), socket_state)
  end

  def terminate(_reason, _req, _state), do: :ok

  defp normalize_reason({:closed, _code, _msg}), do: :closed
  defp normalize_reason(:closed_abruptly), do: :closed
  defp normalize_reason(:stop), do: :shutdown
  defp normalize_reason({:crash, _class, reason}), do: reason
  defp normalize_reason(reason), do: reason

  # -- outgoing --------------------------------------------------------------

  # A push from the socket is either a plain text/binary message (lane 0) or a
  # lane container produced by LaneSerializer.
  defp push_out(state, {:text, iodata}) do
    send_lane(state, @control, {:text, IO.iodata_to_binary(iodata)})
  end

  defp push_out(state, {:binary, iodata}) do
    case IO.iodata_to_binary(iodata) do
      <<"L", count::16, rest::binary>> ->
        rest
        |> lane_frames(count)
        |> Enum.reduce({[], state}, fn {lane, json}, {cmds, st} ->
          {more, st} = send_lane(st, lane, {:text, json})
          {cmds ++ more, st}
        end)

      bin ->
        send_lane(state, @control, {:binary, bin})
    end
  end

  defp lane_frames(<<>>, 0), do: []

  defp lane_frames(<<lane::32, len::32, json::binary-size(len), rest::binary>>, n) do
    [{lane, json} | lane_frames(rest, n - 1)]
  end

  defp send_lane(state, lane, frame) do
    slot = slot_for(lane, state.max_lanes)

    case Map.get(state.lanes, slot) do
      {:open, _stream_id} ->
        send_frame(state, slot, frame)

      {:opening, pending} ->
        {[], %{state | lanes: Map.put(state.lanes, slot, {:opening, pending ++ [frame]})}}

      nil ->
        {cmds, state} = ensure_lane(state, slot)
        {cmds, %{state | lanes: Map.put(state.lanes, slot, {:opening, [frame]})}}
    end
  end

  defp ensure_lane(state, slot) do
    case Map.get(state.lanes, slot) do
      nil ->
        cmd = {:open_stream, {:lane, slot}, :unidi, <<slot::32>>}
        {[cmd], %{state | lanes: Map.put(state.lanes, slot, {:opening, []})}}

      _ ->
        {[], state}
    end
  end

  defp send_frame(%State{closing: true} = state, _slot, _frame), do: {[], state}

  defp send_frame(%State{priority_via: :command} = state, slot, {type, payload}) do
    # Patched cowboy (patches/0001): priority is a first-class command and
    # send errors are cowboy's to handle.
    {:open, stream_id} = Map.fetch!(state.lanes, slot)
    prio = priority_for(byte_size(payload))

    {[{:set_stream_priority, stream_id, prio}, {:send, stream_id, Frame.encode(type, payload)}],
     state}
  end

  defp send_frame(state, slot, {type, payload}) do
    {:open, stream_id} = Map.fetch!(state.lanes, slot)

    case prioritize(state, slot, byte_size(payload)) do
      :closed ->
        # The peer is gone but cowboy has not told us yet (it only reports
        # session-level events). Close now so the LiveView stops rendering
        # for nobody instead of pushing into dead streams until the idle
        # timeout.
        Logger.info("webtransport lane #{slot}: stream closed by peer, ending session")
        {[{:close, 0}], %{state | closing: true}}

      _ ->
        {[{:send, stream_id, Frame.encode(type, payload)}], state}
    end
  end

  # Shortest message first: a 1 KiB frame gets 0xFFFF - 32, a 1 MiB frame
  # 0xFFFF - 32768, so small updates always jump ahead of big ones.
  defp priority_for(size), do: max(@max_priority - div(size, 32), 1)

  # Lane 0 keeps its stream. Component lanes share the remaining slots.
  defp slot_for(@control, _max), do: @control
  defp slot_for(_lane, max) when max <= 1, do: @control
  defp slot_for(lane, max), do: rem(lane - 1, max - 1) + 1

  # -- priority --------------------------------------------------------------

  defp prioritize(%State{refs: refs}, slot, size) do
    case Map.get(refs, slot) do
      nil ->
        :ok

      ref ->
        case :quicer.setopt(ref, :priority, priority_for(size)) do
          :ok ->
            :ok

          {:error, :closed} ->
            :closed

          error ->
            Logger.warning("webtransport lane #{slot}: priority setopt #{inspect(error)}")
            :ok
        end
    end
  end

  defp remember_ref(state, slot, stream_id) do
    case stream_ref(state.conn_pid, stream_id) do
      nil ->
        Logger.warning(
          "webtransport lane #{slot}: stream #{stream_id} has no handle in #{inspect(state.conn_pid)}"
        )

        state

      ref ->
        Logger.debug(
          "webtransport lane #{slot}: stream #{stream_id} handle #{inspect(ref)} " <>
            "id=#{inspect(:quicer.get_stream_id(ref))} prio=#{inspect(:quicer.setopt(ref, :priority, 0x7FFF))}"
        )

        %{state | refs: Map.put(state.refs, slot, ref)}
    end
  end

  # cowboy_quicer keeps `{quicer_stream, StreamID} => Handle` in the
  # connection process's dictionary. Reading another process's dictionary is
  # a debugging facility, acceptable for a prototype and replaced by a cowboy
  # command in the spec.
  defp stream_ref(conn_pid, stream_id) do
    case Process.info(conn_pid, :dictionary) do
      {:dictionary, dict} ->
        List.keyfind(dict, {:quicer_stream, stream_id}, 0) |> then(&if(&1, do: elem(&1, 1)))

      nil ->
        nil
    end
  end
end
