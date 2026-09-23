defmodule PhoenixWebTransport.Cert do
  @moduledoc """
  Development certificate for the WebTransport listener.

  Chrome only accepts a self-signed certificate through the
  `serverCertificateHashes` option, and that option requires an ECDSA P-256
  key and a validity window of at most 14 days. A `mix phx.gen.cert` RSA
  certificate is rejected, so this module generates its own 13-day cert with
  openssl and exposes the SHA-256 of the DER encoding for the page to pin.

  Production deployments terminate QUIC with a publicly trusted certificate
  and never use this module.
  """

  @max_age_days 12
  @openssl_candidates ["/opt/homebrew/opt/openssl@3/bin/openssl", "openssl"]

  @doc "Ensures a fresh cert/key pair exists in `dir` and returns their paths."
  def ensure!(dir) do
    File.mkdir_p!(dir)
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")
    if stale?(cert), do: generate!(cert, key)
    {cert, key}
  end

  @doc "Lowercase hex SHA-256 of the certificate's DER bytes."
  def hash_hex(cert_path) do
    cert_path
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _, :not_encrypted}, &1))
    |> elem(1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stale?(cert) do
    case File.stat(cert, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > @max_age_days * 86_400
      _ -> true
    end
  end

  defp generate!(cert, key) do
    openssl =
      Enum.find_value(@openssl_candidates, &System.find_executable/1) ||
        raise "openssl not found; install openssl@3 with Homebrew"

    args = ~w(req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
              -keyout #{key} -out #{cert} -days 13 -nodes -subj /CN=localhost
              -addext subjectAltName=DNS:localhost,IP:127.0.0.1)

    case System.cmd(openssl, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        raise "openssl exited #{code} while generating the WebTransport cert:\n#{out}"
    end
  end
end
