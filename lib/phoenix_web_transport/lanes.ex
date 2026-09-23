defmodule PhoenixWebTransport.Lanes do
  @moduledoc """
  Lane bookkeeping shared by the session layers (cowboy, erlang_quic).

  A push from the Phoenix socket is either a plain `{:text | :binary, iodata}`
  message, which belongs on the control lane, or a lane container produced by
  `PhoenixWebTransport.LaneSerializer`, which carries one frame per lane.
  """

  @control 0

  @doc "The control lane id."
  def control, do: @control

  @doc "Turns a socket push into `[{lane, {type, payload}}]`."
  @spec frames_for_push({:text | :binary, iodata}) :: [
          {non_neg_integer, {:text | :binary, binary}}
        ]
  def frames_for_push({:text, iodata}), do: [{@control, {:text, IO.iodata_to_binary(iodata)}}]

  def frames_for_push({:binary, iodata}) do
    case IO.iodata_to_binary(iodata) do
      <<"L", count::16, rest::binary>> -> lane_frames(rest, count)
      bin -> [{@control, {:binary, bin}}]
    end
  end

  defp lane_frames(<<>>, 0), do: []

  defp lane_frames(<<lane::32, len::32, json::binary-size(len), rest::binary>>, n) do
    [{lane, {:text, json}} | lane_frames(rest, n - 1)]
  end

  @doc """
  Maps a lane onto one of `max_lanes` stream slots. Lane 0 keeps its own
  stream; component lanes share the remaining slots round-robin.
  """
  def slot_for(@control, _max), do: @control
  def slot_for(_lane, max) when max <= 1, do: @control
  def slot_for(lane, max), do: rem(lane - 1, max - 1) + 1

  @doc """
  Shortest message first on msquic's 16-bit scale: 0xFFFF minus size/32,
  so a 1 KiB frame is 0xFFFF - 32 and a 1 MiB frame 0xFFFF - 32768.
  """
  def msquic_priority(size), do: max(0xFFFF - div(size, 32), 1)

  @doc """
  Shortest message first on the RFC 9218 urgency scale (0 most urgent, 7
  least; erlang_quic reserves 0 for its own control streams).
  """
  def urgency(size) when size < 4_096, do: 1
  def urgency(size) when size < 65_536, do: 3
  def urgency(_size), do: 5
end
