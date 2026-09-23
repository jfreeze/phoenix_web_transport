defmodule PhoenixWebTransport.FrameTest do
  use ExUnit.Case, async: true

  alias PhoenixWebTransport.Frame

  test "round trips text and binary frames" do
    bin = IO.iodata_to_binary([Frame.encode(:text, "hi"), Frame.encode(:binary, <<1, 2, 3>>)])
    assert Frame.decode(bin) == {[{:text, "hi"}, {:binary, <<1, 2, 3>>}], <<>>}
  end

  test "keeps an incomplete trailing frame in the buffer" do
    full = IO.iodata_to_binary(Frame.encode(:text, "hello"))
    {head, tail} = String.split_at(full, 6)

    assert {[], ^head} = Frame.decode(head)
    assert {[{:text, "hello"}], <<>>} = Frame.decode(head <> tail)
  end

  test "decodes several frames arriving in one chunk with a partial next frame" do
    bin = IO.iodata_to_binary([Frame.encode(:text, "a"), Frame.encode(:text, "b"), <<0, 0, 0>>])
    assert {[{:text, "a"}, {:text, "b"}], <<0, 0, 0>>} = Frame.decode(bin)
  end
end
