# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :wt_demo,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :wt_demo, WtDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WtDemoWeb.ErrorHTML, json: WtDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WtDemo.PubSub,
  live_view: [signing_salt: "S9cXL+L9"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# WebTransport listener beside the endpoint (see lib/phoenix_web_transport/listener.ex)
config :wt_demo, PhoenixWebTransport,
  endpoint: WtDemoWeb.Endpoint,
  socket: Phoenix.LiveView.Socket,
  path: "/live",
  port: String.to_integer(System.get_env("WT_PORT") || "4433"),
  cert_dir: "priv/cert",
  check_origin:
    Enum.map(["localhost", "127.0.0.1"], &"http://#{&1}:#{System.get_env("PORT") || "4000"}"),
  max_lanes: 16,
  # :command needs the cowboy patch in ../patches applied to deps/cowboy
  stream_priority: if(System.get_env("WT_PRIORITY") == "command", do: :command, else: :peek)

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wt_demo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  wt_demo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
