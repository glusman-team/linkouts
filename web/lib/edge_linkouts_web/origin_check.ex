defmodule EdgeLinkoutsWeb.OriginCheck do
  @moduledoc """
  Origin lockdown: only requests carrying the shared `X-Origin-Key` header reach the app.

  `edge-linkouts.fly.dev` is Fly platform plumbing; it cannot be deleted while the app
  exists, and Cloudflare reaches the origin through it. Without a check, an attacker can
  bypass the CDN (and its DDoS protection) by hitting the fly.dev hostname directly,
  spending the Cosmos RU budget nobody is watching. A Cloudflare Transform Rule on the
  zone adds the header to every proxied request; everything else gets a bare 403 before
  any route, LiveView, or store read runs.

  Enabled only in production, where `config/runtime.exs` copies `X_ORIGIN_KEY` into
  `config :edge_linkouts, :origin_check_key`. Local development and the test suite never
  set it, so they pass through untouched - and a stray `X_ORIGIN_KEY` in a developer's
  shell (direnv) cannot leak into a test run the way a per-request `System.get_env/1`
  read once did.

  The comparison is `Plug.Crypto.secure_compare/2` (constant time): the header is a
  shared secret, and a plain `==` would let a timing oracle leak it byte by byte.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:edge_linkouts, :origin_check_key) do
      nil ->
        conn

      key ->
        case Plug.Conn.get_req_header(conn, "x-origin-key") do
          [sent] ->
            if Plug.Crypto.secure_compare(key, sent) do
              conn
            else
              forbid(conn)
            end

          [] ->
            forbid(conn)
        end
    end
  end

  defp forbid(conn) do
    conn
    |> Plug.Conn.send_resp(403, "forbidden")
    |> Plug.Conn.halt()
  end
end
