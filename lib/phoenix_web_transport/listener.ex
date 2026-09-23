defmodule PhoenixWebTransport.Listener do
  @moduledoc """
  Starts a cowboy HTTP/3 (QUIC) listener that only serves WebTransport
  sessions for one Phoenix socket.

  The regular Phoenix endpoint keeps serving HTTP/1.1 and WebSocket on its
  own port; this listener runs beside it on a UDP port. Nothing in the
  endpoint changes, which is what makes this shippable as a library.

  ## Options

    * `:endpoint` - the Phoenix endpoint module (required)
    * `:socket` - the socket module, e.g. `Phoenix.LiveView.Socket` (required)
    * `:path` - the socket mount path, default `"/live"`
    * `:port` - UDP port, default `4433`
    * `:cert_dir` - where the dev cert lives, default `"priv/cert"`
    * `:certfile` / `:keyfile` - explicit paths (skip cert generation)
    * `:check_origin` - list of allowed Origin values, or `false`
    * `:max_lanes` - maximum server streams per session, default 16
    * `:stream_priority` - `:peek` (default) or `:command` (patched cowboy), see `PhoenixWebTransport.Handler`
    * `:enabled` - set to `false` (test env) to skip the listener entirely
    * `:url` - the URL pages should connect to; defaults to `https://localhost:<port><path>`
  """

  use GenServer

  require Logger

  @default_port 4433

  def start_link(opts) do
    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: __MODULE__),
      else: :ignore
  end

  @doc "Whether a listener is running in this VM."
  def enabled?, do: :persistent_term.get({__MODULE__, :opts}, nil) != nil

  @doc "The public URL a page should hand to `LiveSocket`, or nil when not running."
  def url do
    case running_opts() do
      nil -> nil
      opts -> Keyword.get(opts, :url) || default_url(opts)
    end
  end

  @doc "Hex SHA-256 of the served cert for `serverCertificateHashes`, or nil when not running."
  def cert_hash do
    case running_opts() do
      nil -> nil
      opts -> opts |> cert_paths() |> elem(0) |> PhoenixWebTransport.Cert.hash_hex()
    end
  end

  defp running_opts, do: :persistent_term.get({__MODULE__, :opts}, nil)

  defp default_url(opts) do
    "https://localhost:#{Keyword.get(opts, :port, @default_port)}#{Keyword.get(opts, :path, "/live")}"
  end

  @impl true
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    socket = Keyword.fetch!(opts, :socket)
    path = Keyword.get(opts, :path, "/live")
    port = Keyword.get(opts, :port, @default_port)
    {certfile, keyfile} = cert_paths(opts)

    socket_opts = [
      serializer: [{PhoenixWebTransport.LaneSerializer, "~> 2.0.0"}],
      check_origin: Keyword.get(opts, :check_origin, false),
      max_lanes: Keyword.get(opts, :max_lanes, 16),
      stream_priority: Keyword.get(opts, :stream_priority, :peek)
    ]

    dispatch =
      :cowboy_router.compile([
        {:_, [{~c"#{path}/[...]", PhoenixWebTransport.Handler, {endpoint, socket, socket_opts}}]}
      ])

    proto_opts = %{
      env: %{dispatch: dispatch},
      enable_connect_protocol: true,
      h3_datagram: true,
      enable_webtransport: true,
      wt_max_sessions: 100
    }

    trans_opts = %{
      socket_opts: [
        port: port,
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        # A peer that vanishes without CONNECTION_CLOSE is dropped after this,
        # which ends its LiveView instead of buffering diffs for nobody.
        idle_timeout_ms: 30_000
      ]
    }

    # Called dynamically: cowboy only exports start_quic/3 when compiled with
    # the COWBOY_QUICER macro (scripts/build_quic.sh), and the test env is not.
    Code.ensure_loaded!(:cowboy)

    unless function_exported?(:cowboy, :start_quic, 3) do
      raise "cowboy was compiled without HTTP/3 support; run `mix deps.quic`"
    end

    {:ok, listener} = apply(:cowboy, :start_quic, [__MODULE__, trans_opts, proto_opts])
    :persistent_term.put({__MODULE__, :opts}, opts)
    Logger.info("WebTransport listener on udp://0.0.0.0:#{port}#{path} (cert #{certfile})")
    {:ok, %{listener: listener}}
  end

  @impl true
  def terminate(_reason, %{listener: listener}) do
    :persistent_term.erase({__MODULE__, :opts})
    :quicer.close_listener(listener)
    :ok
  end

  defp cert_paths(opts) do
    case {Keyword.get(opts, :certfile), Keyword.get(opts, :keyfile)} do
      {cert, key} when is_binary(cert) and is_binary(key) ->
        {cert, key}

      _ ->
        opts
        |> Keyword.get(:cert_dir, "priv/cert")
        |> Path.expand()
        |> PhoenixWebTransport.Cert.ensure!()
    end
  end
end
