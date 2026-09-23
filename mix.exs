defmodule PhoenixWebTransport.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jfreeze/phoenix_web_transport"

  def project do
    [
      app: :phoenix_web_transport,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "WebTransport (HTTP/3, QUIC) transport for Phoenix sockets and LiveView: " <>
          "one QUIC stream per component, shortest-message-first scheduling.",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "docs/SPEC.md"]],
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger, :public_key, :crypto]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      # cowboy provides the HTTP/3 + WebTransport session layer. It must be
      # compiled with the COWBOY_QUICER macro; see scripts/build_quic.sh.
      {:cowboy, "~> 2.19"},
      {:quicer, "~> 0.4.8"},
      # Pure Erlang QUIC + HTTP/3 (extended CONNECT, datagrams, stream priority).
      # Alternative session layer to cowboy+quicer; see PhoenixWebTransport.Quic.
      {:quic, github: "benoitc/erlang_quic", branch: "main"},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "deps.quic": ["cmd scripts/build_quic.sh"],
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib assets/js scripts/build_quic.sh package.json mix.exs README.md LICENSE docs)
    ]
  end
end
