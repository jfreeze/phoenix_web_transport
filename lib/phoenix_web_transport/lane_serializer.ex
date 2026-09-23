defmodule PhoenixWebTransport.LaneSerializer do
  @moduledoc """
  A `Phoenix.Socket.Serializer` that splits one LiveView `diff` push into
  several independently deliverable frames, one per updated component.

  The wire format of every frame is identical to the V2 JSON serializer, so
  the browser side needs no changes beyond delivering frames from several
  streams into the same `phoenix.js` socket. What changes is the *packaging*:
  instead of one `{:socket_push, :text, json}` this serializer returns

      {:socket_push, :binary, <<"L", count::16, (lane::32, len::32, json)*>>}

  and the transport maps each lane onto its own QUIC stream.

  ## Which parts of a diff may travel alone

  A component diff in `c` that carries no `s` (statics) key is a pure delta to
  a component the client already knows. It depends on nothing else in the
  same message, so it goes on lane `cid`.

  Everything else stays together on lane 0 (the control lane): the root
  diff, new or reset components (they carry `s` and the root usually
  references them), components that share statics with a sibling in the same
  diff (`s` is a positive cid), events, title, replies, joins and heartbeats.
  Lane 0 is also where all messages of other serializers' shape go, so a
  socket that never renders components behaves exactly like WebSocket.
  """

  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Broadcast, Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer, as: V2

  @control 0

  @impl true
  def fastlane!(%Broadcast{} = msg), do: V2.fastlane!(msg)

  @impl true
  def decode!(raw, opts), do: V2.decode!(raw, opts)

  @impl true
  def encode!(%Reply{} = reply), do: V2.encode!(reply)

  def encode!(%Message{event: "diff", payload: %{} = payload} = msg) do
    case split_components(payload) do
      {_control, []} ->
        V2.encode!(msg)

      {control, independent} ->
        control_frames =
          if map_size(control) == 0 and is_nil(msg.ref),
            do: [],
            else: [{@control, encode_json([msg.join_ref, msg.ref, msg.topic, "diff", control])}]

        lane_frames =
          for {cid, cdiff} <- independent do
            {cid, encode_json([msg.join_ref, nil, msg.topic, "diff", %{c: %{cid => cdiff}}])}
          end

        {:socket_push, :binary, container(control_frames ++ lane_frames)}
    end
  end

  def encode!(%Message{} = msg), do: V2.encode!(msg)

  @doc """
  Splits a diff payload into `{control_payload, [{cid, component_diff}]}`.

  Exposed for tests and for the spec; see the moduledoc for the rule.
  """
  def split_components(payload) do
    {ckey, components} = fetch_components(payload)

    {independent, dependent} =
      Enum.split_with(components, fn {cid, cdiff} -> independent?(cid, cdiff) end)

    control =
      case dependent do
        [] -> Map.delete(payload, ckey)
        deps -> Map.put(payload, ckey, Map.new(deps))
      end

    {control, independent}
  end

  defp fetch_components(payload) do
    cond do
      is_map(payload[:c]) -> {:c, payload[:c]}
      is_map(payload["c"]) -> {"c", payload["c"]}
      true -> {:c, %{}}
    end
  end

  defp independent?(cid, cdiff) when is_map(cdiff) do
    lane_id?(cid) and not Map.has_key?(cdiff, :s) and not Map.has_key?(cdiff, "s")
  end

  defp independent?(_cid, _cdiff), do: false

  defp lane_id?(cid) when is_integer(cid) and cid > 0, do: true
  defp lane_id?(cid) when is_binary(cid), do: match?({n, ""} when n > 0, Integer.parse(cid))
  defp lane_id?(_), do: false

  defp container(frames) do
    [
      <<"L", length(frames)::16>>
      | Enum.map(frames, fn {lane, json} ->
          [<<lane_int(lane)::32, IO.iodata_length(json)::32>>, json]
        end)
    ]
  end

  defp lane_int(lane) when is_integer(lane), do: lane
  defp lane_int(lane) when is_binary(lane), do: String.to_integer(lane)

  defp encode_json(data), do: Phoenix.json_library().encode_to_iodata!(data)
end
