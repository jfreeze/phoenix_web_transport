defmodule WtDemoWeb.DemoLive do
  @moduledoc """
  One LiveView, two components, one transport.

  `HeavyComponent` re-renders a large table on every heavy tick, producing a
  diff of hundreds of kilobytes. `PulseComponent` updates a tiny counter on
  every pulse tick and stamps it with the server clock. A client hook measures
  how long each pulse took to reach the DOM.

  Over WebSocket both diffs share one ordered TCP stream, so a pulse queued
  behind a heavy diff waits for the whole heavy diff to arrive. Over
  WebTransport each component has its own QUIC stream and the pulse is
  delivered as soon as its packet lands.

  Query parameters: `transport` (`ws` or `wt`), `rows`, `heavy_ms`, `pulse_ms`.
  """

  use WtDemoWeb, :live_view

  alias WtDemoWeb.{HeavyComponent, PulseComponent}

  @defaults %{transport: "ws", rows: 3000, heavy_ms: 400, pulse_ms: 100}
  @max_rows 20_000

  @impl true
  def mount(params, _session, socket) do
    settings = settings(params)

    socket =
      socket
      |> assign(settings)
      |> assign(page_title: "Demo (#{settings.transport})", tick: 0, seq: 0, running: false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    settings = settings(params)
    socket = assign(socket, settings)

    if connected?(socket) and not socket.assigns.running do
      Process.send_after(self(), :heavy, settings.heavy_ms)
      Process.send_after(self(), :pulse, settings.pulse_ms)
      {:noreply, assign(socket, running: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:heavy, socket) do
    Process.send_after(self(), :heavy, socket.assigns.heavy_ms)
    tick = socket.assigns.tick + 1

    send_update(HeavyComponent,
      id: "heavy",
      tick: tick,
      rows: socket.assigns.rows,
      sent_at: now()
    )

    {:noreply, assign(socket, tick: tick)}
  end

  def handle_info(:pulse, socket) do
    Process.send_after(self(), :pulse, socket.assigns.pulse_ms)
    seq = socket.assigns.seq + 1
    send_update(PulseComponent, id: "pulse", seq: seq, sent_at: now())
    {:noreply, assign(socket, seq: seq)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4" data-transport={@transport}>
      <header class="flex items-baseline justify-between gap-4">
        <h1 class="text-xl font-semibold">
          {transport_name(@transport)}
        </h1>
        <p class="text-sm opacity-70">
          {@rows} rows every {@heavy_ms} ms · pulse every {@pulse_ms} ms
        </p>
      </header>

      <div
        id="stats"
        phx-hook="StatsPanel"
        phx-update="ignore"
        class="font-mono text-sm grid grid-cols-2 gap-x-6 gap-y-1"
      >
        <span class="opacity-60">pulse latency, lower is better (last / p50 / p95 / max)</span>
        <span data-stat="pulse">–</span>
        <span class="opacity-60">heavy table latency (last / p50 / max)</span>
        <span data-stat="heavy">–</span>
        <span class="opacity-60">pulses received</span>
        <span data-stat="pulses">0</span>
        <span class="opacity-60">bytes received</span>
        <span data-stat="bytes">0</span>
        <span class="opacity-60">streams (lane: frames / bytes)</span>
        <span data-stat="lanes">–</span>
      </div>

      <img :if={@hold_ms > 0} src={"/hold?ms=#{@hold_ms}"} alt="" width="1" height="1" />
      <.live_component module={PulseComponent} id="pulse" seq={0} sent_at={now()} />
      <.live_component module={HeavyComponent} id="heavy" tick={0} rows={@rows} sent_at={now()} />
    </div>
    """
  end

  defp settings(params) do
    %{
      transport: if(params["transport"] == "wt", do: "wt", else: "ws"),
      rows: int(params["rows"], @defaults.rows) |> min(@max_rows) |> max(1),
      heavy_ms: int(params["heavy_ms"], @defaults.heavy_ms) |> max(50),
      pulse_ms: int(params["pulse_ms"], @defaults.pulse_ms) |> max(20),
      hold_ms: int(params["hold"], 0)
    }
  end

  defp int(nil, default), do: default

  defp int(value, default) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp now, do: System.system_time(:millisecond)

  defp transport_name("wt"), do: "WebTransport · one QUIC stream per component"
  defp transport_name(_), do: "WebSocket · one TCP stream"
end
