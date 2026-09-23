defmodule WtDemoWeb.DemoLiveTest do
  use WtDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders both components and honours the scenario params", %{conn: conn} do
    {:ok, view, html} = live(conn, "/demo?transport=wt&rows=5&heavy_ms=100&pulse_ms=50")

    assert html =~ "WebTransport · one QUIC stream per component"
    assert has_element?(view, "#pulse[phx-hook=LatencyMeter]")
    assert has_element?(view, "#heavy[phx-hook=HeavyMeter]")
    assert render(view) =~ "5 rows"
  end

  test "ticks update the components", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo?rows=3&heavy_ms=50&pulse_ms=50")
    Process.sleep(120)
    assert render(view) =~ ~r/data-seq="[1-9]/
    assert render(view) =~ ~r/data-tick="[1-9]/
  end

  test "compare page embeds one frame per transport", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?rows=100")
    assert html =~ "/demo?transport=ws&amp;"
    assert html =~ "/demo?transport=wt&amp;"
  end
end
