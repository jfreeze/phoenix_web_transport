defmodule WtDemoWeb.HeavyComponent do
  @moduledoc """
  A table whose every cell changes on every tick, so each update produces a
  diff proportional to `rows * 8` short tokens.
  """

  use WtDemoWeb, :live_component

  @cols 8

  @impl true
  def update(assigns, socket) do
    rows = for i <- 1..assigns.rows, do: {i, for(c <- 1..@cols, do: token(assigns.tick, i, c))}
    {:ok, socket |> assign(assigns) |> assign(rows: rows)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="HeavyMeter"
      data-tick={@tick}
      data-sent-at={@sent_at}
      class="text-xs font-mono"
    >
      <div class="flex items-baseline gap-3 mb-2">
        <span class="text-base font-semibold">heavy</span>
        <span class="opacity-70">tick {@tick} · {length(@rows)} rows</span>
      </div>
      <div class="max-h-64 overflow-auto border border-base-300 rounded">
        <table class="table table-xs">
          <tbody>
            <tr :for={{i, cells} <- @rows}>
              <td class="opacity-50">{i}</td>
              <td :for={cell <- cells}>{cell}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp token(tick, i, c), do: :erlang.phash2({tick, i, c}) |> Integer.to_string(36)
end
