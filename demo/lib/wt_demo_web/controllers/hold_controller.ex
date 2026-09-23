defmodule WtDemoWeb.HoldController do
  @moduledoc """
  Test harness helper. `GET /hold?ms=8000` sleeps and then returns a 1x1 gif.
  A page that embeds it as an image keeps its `load` event pending, which lets
  headless Chrome's `--dump-dom` capture the LiveView after it has been
  running for a while instead of at first paint.
  """

  use WtDemoWeb, :controller

  @gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
  @max_ms 30_000

  def hold(conn, params) do
    ms =
      params
      |> Map.get("ms", "0")
      |> Integer.parse()
      |> then(fn
        {n, _} -> n
        :error -> 0
      end)

    Process.sleep(min(max(ms, 0), @max_ms))
    conn |> put_resp_content_type("image/gif") |> send_resp(200, @gif)
  end
end
