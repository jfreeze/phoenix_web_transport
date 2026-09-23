defmodule WtDemoWeb.CompareLive do
  @moduledoc """
  Side-by-side comparison: the same scenario over WebSocket and WebTransport.

  Two iframes share this tab's main thread, so their JSON parsing and DOM
  patching interfere with each other. The numbers are still telling, but for
  clean measurements open each transport in its own tab with the links below.
  """

  use WtDemoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Compare")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    form = %{
      "rows" => params["rows"] || "3000",
      "heavy_ms" => params["heavy_ms"] || "400",
      "pulse_ms" => params["pulse_ms"] || "100"
    }

    {:noreply, assign(socket, form: to_form(form), query: URI.encode_query(form))}
  end

  @impl true
  def handle_event("apply", params, socket) do
    query = Map.take(params, ["rows", "heavy_ms", "pulse_ms"])
    {:noreply, push_patch(socket, to: ~p"/?#{query}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4 max-w-7xl mx-auto">
      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">LiveView over WebTransport</h1>
        <p class="opacity-70">
          Same LiveView, same diffs. Left: one WebSocket. Right: one QUIC stream per component with
          shortest-message-first priority. Watch the pulse latency while the heavy table streams.
        </p>
      </header>

      <.form for={@form} phx-submit="apply" class="flex flex-wrap items-end gap-3">
        <label class="form-control">
          <span class="label-text">rows</span>
          <input
            type="number"
            name="rows"
            value={@form[:rows].value}
            class="input input-bordered input-sm w-28"
          />
        </label>
        <label class="form-control">
          <span class="label-text">heavy every (ms)</span>
          <input
            type="number"
            name="heavy_ms"
            value={@form[:heavy_ms].value}
            class="input input-bordered input-sm w-28"
          />
        </label>
        <label class="form-control">
          <span class="label-text">pulse every (ms)</span>
          <input
            type="number"
            name="pulse_ms"
            value={@form[:pulse_ms].value}
            class="input input-bordered input-sm w-28"
          />
        </label>
        <button class="btn btn-sm btn-primary">Apply</button>
        <span class="ml-auto text-sm flex gap-3">
          <a class="link" href={"/demo?transport=ws&" <> @query} target="_blank">WebSocket in its own tab</a>
          <a class="link" href={"/demo?transport=wt&" <> @query} target="_blank">WebTransport in its own tab</a>
        </span>
      </.form>

      <section
        id="scoreboard"
        phx-hook="Scoreboard"
        phx-update="ignore"
        class="card bg-base-200 p-4 space-y-3"
      >
        <p data-verdict class="font-medium">Collecting samples…</p>
        <table class="table table-sm w-auto font-mono">
          <thead>
            <tr>
              <th class="font-sans font-normal opacity-60">lower is better</th>
              <th>WebSocket</th>
              <th>WebTransport</th>
            </tr>
          </thead>
          <tbody>
            <tr data-row="p95">
              <td class="font-sans">
                pulse latency p95 <span class="opacity-60">(the number that matters)</span>
              </td><td>–</td><td>–</td>
            </tr>
            <tr data-row="max">
              <td class="font-sans">pulse latency max</td><td>–</td><td>–</td>
            </tr>
            <tr data-row="p50">
              <td class="font-sans">pulse latency p50</td><td>–</td><td>–</td>
            </tr>
            <tr data-row="heavy">
              <td class="font-sans">
                heavy table latency p50
                <span class="opacity-60">(should be similar; WT deprioritises it)</span>
              </td><td>–</td><td>–</td>
            </tr>
            <tr data-row="bytes">
              <td class="font-sans">
                bytes received <span class="opacity-60">(same payload both sides)</span>
              </td><td>–</td><td>–</td>
            </tr>
          </tbody>
        </table>
        <p class="text-sm opacity-70">
          Each pane sends a tiny "pulse" update every {@form[:pulse_ms].value} ms while a {@form[
            :rows
          ].value}-row table
          re-renders every {@form[:heavy_ms].value} ms. Pulse latency is how long a pulse took from the server clock to the DOM.
          On one TCP stream a pulse waits behind whatever table bytes are still in flight; on its own QUIC stream it does not.
        </p>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <iframe
          id={"ws-" <> @query}
          src={"/demo?transport=ws&" <> @query}
          class="w-full h-[36rem] border border-base-300 rounded"
        ></iframe>
        <iframe
          id={"wt-" <> @query}
          src={"/demo?transport=wt&" <> @query}
          class="w-full h-[36rem] border border-base-300 rounded"
        ></iframe>
      </div>

      <p class="text-sm opacity-70">
        Loopback is too fast to show the difference. Run <code>scripts/impair.sh on</code> (sudo) to
        cap both ports at 20 Mbit/s with 20 ms delay, then <code>scripts/impair.sh off</code>.
      </p>
    </div>
    """
  end
end
