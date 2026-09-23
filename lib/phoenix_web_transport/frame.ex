defmodule PhoenixWebTransport.Frame do
  @moduledoc """
  Wire framing shared by the server handler and the browser transport.

  QUIC streams are byte streams, so every channel message is framed as

      <<length::32, type::8, payload::binary-size(length - 1)>>

  where `type` is `0` for a text (JSON) message and `1` for a binary one.
  The 32-bit length covers the type byte and the payload.

  Each server-initiated unidirectional stream starts with a 4-byte lane id
  before its first frame; see `PhoenixWebTransport.Handler`.
  """

  @text 0
  @binary 1

  @spec encode(:text | :binary, binary) :: iodata
  def encode(:text, payload), do: [<<byte_size(payload) + 1::32, @text>>, payload]
  def encode(:binary, payload), do: [<<byte_size(payload) + 1::32, @binary>>, payload]

  @doc "Splits a buffer into complete frames and the unconsumed remainder."
  @spec decode(binary) :: {[{:text | :binary, binary}], binary}
  def decode(buffer), do: decode(buffer, [])

  defp decode(<<len::32, rest::binary>>, acc) when byte_size(rest) >= len and len >= 1 do
    size = len - 1
    <<type::8, payload::binary-size(^size), rest::binary>> = rest
    decode(rest, [{type_of(type), payload} | acc])
  end

  defp decode(buffer, acc), do: {Enum.reverse(acc), buffer}

  defp type_of(@text), do: :text
  defp type_of(@binary), do: :binary
end
