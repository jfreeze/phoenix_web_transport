defmodule WtDemoWeb.PulseComponent do
  @moduledoc """
  A tiny component: a sequence number and the server time it was sent.
  Its diff is a few dozen bytes. The `LatencyMeter` hook measures the time
  from `sent_at` to the DOM update.
  """

  use WtDemoWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="LatencyMeter"
      data-seq={@seq}
      data-sent-at={@sent_at}
      class="flex items-baseline gap-3"
    >
      <span class="text-base font-semibold">pulse</span>
      <span class="font-mono text-2xl tabular-nums">{@seq}</span>
    </div>
    """
  end
end
