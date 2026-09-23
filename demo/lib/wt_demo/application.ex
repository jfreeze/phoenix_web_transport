defmodule WtDemo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WtDemoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:wt_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WtDemo.PubSub},
      # Start a worker by calling: WtDemo.Worker.start_link(arg)
      # {WtDemo.Worker, arg},
      # Start to serve requests, typically the last entry
      WtDemoWeb.Endpoint,
      # WebTransport (HTTP/3) listener for the same LiveView socket, beside the endpoint.
      {PhoenixWebTransport.Listener, Application.get_env(:wt_demo, PhoenixWebTransport, [])}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WtDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WtDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
