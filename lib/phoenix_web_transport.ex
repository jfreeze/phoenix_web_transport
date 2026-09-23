defmodule PhoenixWebTransport do
  @moduledoc """
  WebTransport (HTTP/3 over QUIC) as a transport for Phoenix sockets and
  LiveView, with one QUIC stream per LiveView component and
  shortest-message-first scheduling.

  Add one listener to your supervision tree next to the endpoint:

    * `PhoenixWebTransport.Quic.Listener` (default): pure Erlang, on
      benoitc/erlang_quic. No native build.
    * `PhoenixWebTransport.Cowboy.Listener` (optional): cowboy's experimental
      HTTP/3 + WebTransport on the msquic NIF. Needs `cowboy` and `quicer`
      as dependencies and `mix deps.quic`.

  Both register here, so pages can ask `url/0` and `cert_hash/0` for the
  `<meta>` tags the browser class reads.
  """

  @key {__MODULE__, :opts}

  @doc false
  def register(opts), do: :persistent_term.put(@key, opts)

  @doc false
  def unregister, do: :persistent_term.erase(@key)

  @doc "Whether a WebTransport listener is running in this VM."
  def enabled?, do: :persistent_term.get(@key, nil) != nil

  @doc "The URL pages should hand to `LiveSocket`, or nil when no listener runs."
  def url do
    case :persistent_term.get(@key, nil) do
      nil -> nil
      opts -> Keyword.get(opts, :url) || default_url(opts)
    end
  end

  @doc "Hex SHA-256 of the served dev cert for `serverCertificateHashes`, or nil."
  def cert_hash do
    case :persistent_term.get(@key, nil) do
      nil ->
        nil

      opts ->
        case {Keyword.get(opts, :certfile), Keyword.get(opts, :cert_dir, "priv/cert")} do
          {cert, _} when is_binary(cert) ->
            PhoenixWebTransport.Cert.hash_hex(cert)

          {nil, dir} ->
            dir |> Path.expand() |> Path.join("cert.pem") |> PhoenixWebTransport.Cert.hash_hex()
        end
    end
  end

  defp default_url(opts) do
    "https://localhost:#{Keyword.get(opts, :port, 4433)}#{Keyword.get(opts, :path, "/live")}"
  end
end
