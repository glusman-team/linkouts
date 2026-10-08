defmodule EdgeLinkoutsWeb.OriginCheck do
  @moduledoc """
  Origin lockdown: only requests carrying the shared `X-Origin-Key` header reach the app.

  `edge-linkouts.fly.dev` is Fly platform plumbing; it cannot be deleted while the app
  exists, and Cloudflare reaches the origin through it. Without a check, an attacker can
  bypass the CDN (and its DDoS protection) by hitting the fly.dev hostname directly,
  spending the Cosmos RU budget nobody is watching. A Cloudflare Transform Rule on the
  zone adds the header to every proxied request; everything else gets a bare 403 before
  any route, LiveView, or store read runs.

  Enabled only when `X_ORIGIN_KEY` is in the environment (set as a Fly secret), so
  local development and the test suite pass through untouched.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case System.get_env("X_ORIGIN_KEY") do
      nil ->
        conn

      key ->
        if Plug.Conn.get_req_header(conn, "x-origin-key") == [key] do
          conn
        else
          conn
          |> Plug.Conn.send_resp(403, "forbidden")
          |> Plug.Conn.halt()
        end
    end
  end
end
