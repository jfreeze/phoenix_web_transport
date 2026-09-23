defmodule PhoenixWebTransport.Quic.Listener do
  @moduledoc """
  WebTransport listener on `erlang_quic` (benoitc/erlang_quic), a pure Erlang
  QUIC + HTTP/3 stack. No native build, no cowboy.

  erlang_quic ships the primitives WebTransport needs (extended CONNECT,
  HTTP datagrams, claiming the WebTransport stream types, RFC 9218 stream
  priority in its send path) and leaves the session protocol to a library.
  This module is that library for one Phoenix socket: it starts the HTTP/3
  server and spawns a `PhoenixWebTransport.Quic.Session` per connection.

  Options: `:endpoint`, `:socket` (required); `:path` (default `"/live"`),
  `:port` (default 4433), `:cert_dir` or `:certfile`/`:keyfile`,
  `:check_origin` (list or `false`), `:max_lanes` (default 16), `:url`
  (what pages connect to), `:enabled` (`false` skips the listener).
  """

  use GenServer

  require Logger

  alias PhoenixWebTransport.Quic.Session

  @default_port 4433
  # SETTINGS ids: legacy ENABLE_WEBTRANSPORT (draft-02), WT_MAX_SESSIONS
  # (drafts 07-13). erlang_quic's own `wt_enabled` is the draft-15 id.
  @enable_webtransport_legacy 0x2B603742
  @wt_max_sessions 0xC671706A

  def start_link(opts) do
    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: __MODULE__),
      else: :ignore
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    {certfile, keyfile} = cert_paths(opts)
    {cert_der, key} = load_cert_and_key(certfile, keyfile)
    session_opts = Session.options(opts)

    server_opts = %{
      cert: cert_der,
      key: key,
      alpn: ["h3"],
      # Dual-stack: browsers resolve localhost to ::1 first. quic_h3 forwards
      # only `quic_opts` to the QUIC listener.
      quic_opts: %{extra_socket_opts: [:inet6, {:ipv6_v6only, false}]},
      settings: %{
        @enable_webtransport_legacy => 1,
        @wt_max_sessions => 100,
        enable_connect_protocol: 1,
        h3_datagram: 1,
        wt_enabled: 1
      },
      h3_datagram_enabled: true,
      stream_type_handler: &claim/3,
      connection_handler: fn quic_conn ->
        {:ok, owner} = Session.start(quic_conn, session_opts)
        # Requests are delivered to the owner; the per-request handler is a no-op.
        %{owner: owner, handler: fn _conn, _sid, _method, _path, _headers -> :ok end}
      end
    }

    if System.get_env("WT_DEBUG") do
      :logger.set_module_level(
        [:quic_connection, :quic_tls, :quic_h3_connection, :quic_listener, :quic_socket],
        :debug
      )
    end

    {:ok, server} = :quic_h3.start_server(__MODULE__, port, server_opts)
    PhoenixWebTransport.register(opts)
    Logger.info("WebTransport (erlang_quic) listener on udp://0.0.0.0:#{port} (cert #{certfile})")
    {:ok, %{server: server}}
  end

  @impl true
  def terminate(_reason, _state) do
    PhoenixWebTransport.unregister()
    :quic_h3.stop_server(__MODULE__)
    :ok
  end

  # WebTransport stream types: WT_STREAM (uni) and WT_BIDI_SIGNAL (bidi).
  defp claim(:uni, _stream_id, 0x54), do: :claim
  defp claim(:bidi, _stream_id, 0x41), do: :claim
  defp claim(_dir, _stream_id, _type), do: :ignore

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

  defp load_cert_and_key(certfile, keyfile) do
    [{:Certificate, cert_der, :not_encrypted}] =
      certfile |> File.read!() |> :public_key.pem_decode()

    key =
      case keyfile |> File.read!() |> :public_key.pem_decode() do
        [{:PrivateKeyInfo, der, :not_encrypted}] -> :public_key.der_decode(:PrivateKeyInfo, der)
        [{:ECPrivateKey, der, :not_encrypted}] -> :public_key.der_decode(:ECPrivateKey, der)
        [{:RSAPrivateKey, der, :not_encrypted}] -> :public_key.der_decode(:RSAPrivateKey, der)
      end

    {cert_der, key}
  end
end
