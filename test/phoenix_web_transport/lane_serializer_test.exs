defmodule PhoenixWebTransport.LaneSerializerTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.Message
  alias PhoenixWebTransport.LaneSerializer

  defp diff(payload, opts \\ []) do
    %Message{
      topic: "lv:phx-1",
      event: "diff",
      payload: payload,
      join_ref: "1",
      ref: Keyword.get(opts, :ref)
    }
  end

  defp lanes({:socket_push, :binary, iodata}) do
    <<"L", count::16, rest::binary>> = IO.iodata_to_binary(iodata)
    parse_lanes(rest, count)
  end

  defp parse_lanes(<<>>, 0), do: []

  defp parse_lanes(<<lane::32, len::32, json::binary-size(len), rest::binary>>, n) do
    [{lane, Jason.decode!(json)} | parse_lanes(rest, n - 1)]
  end

  test "component updates without statics travel on their own lanes" do
    payload = %{0 => "root changed", c: %{1 => %{0 => "pulse"}, 2 => %{0 => "heavy"}}}

    assert [{0, control}, {1, lane1}, {2, lane2}] = lanes(LaneSerializer.encode!(diff(payload)))

    assert control == ["1", nil, "lv:phx-1", "diff", %{"0" => "root changed"}]
    assert lane1 == ["1", nil, "lv:phx-1", "diff", %{"c" => %{"1" => %{"0" => "pulse"}}}]
    assert lane2 == ["1", nil, "lv:phx-1", "diff", %{"c" => %{"2" => %{"0" => "heavy"}}}]
  end

  test "new components (with statics) stay with the root on the control lane" do
    payload = %{c: %{1 => %{0 => "delta"}, 3 => %{0 => "x", s: ["<b>", "</b>"]}}}

    assert [{0, control}, {1, _}] = lanes(LaneSerializer.encode!(diff(payload)))
    assert %{"c" => %{"3" => %{"s" => _}}} = List.last(control)
    refute Map.has_key?(List.last(control)["c"], "1")
  end

  test "a diff with only independent components sends no control frame" do
    payload = %{c: %{7 => %{0 => "only"}}}
    assert [{7, _}] = lanes(LaneSerializer.encode!(diff(payload)))
  end

  test "a diff with nothing to split is plain V2 JSON" do
    payload = %{0 => "root only"}
    assert {:socket_push, :text, _} = LaneSerializer.encode!(diff(payload))

    reset = %{c: %{1 => %{0 => "x", s: 2}}}
    assert {:socket_push, :text, _} = LaneSerializer.encode!(diff(reset))
  end

  test "string keys from already-encoded diffs are handled" do
    payload = %{"c" => %{"4" => %{"0" => "v"}}, "t" => "title"}
    assert [{0, control}, {4, _}] = lanes(LaneSerializer.encode!(diff(payload)))
    assert List.last(control) == %{"t" => "title"}
  end

  test "non-diff messages and decoding are unchanged from V2" do
    msg = %Message{topic: "phoenix", event: "heartbeat", payload: %{}, join_ref: nil, ref: "9"}
    assert LaneSerializer.encode!(msg) == Phoenix.Socket.V2.JSONSerializer.encode!(msg)

    raw = Jason.encode!(["1", "2", "lv:phx-1", "event", %{"type" => "click"}])
    assert %Message{event: "event"} = LaneSerializer.decode!(raw, opcode: :text)
  end
end
