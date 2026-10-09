defmodule EdgeLinkoutsWeb.SecurityHeaders do
  @moduledoc """
  Content-Security-Policy plus the standard secure browser headers, via a per-request nonce.

  Why a nonce: the root layout carries one inline script (the dark-mode pre-paint toggle,
  which must run before first paint to avoid a flash), so `script-src 'self'` alone would
  block it and `'unsafe-inline'` would re-open the XSS hole the policy exists to close. A
  fresh random nonce per request allows exactly that script and nothing else injected.

  Directive choices:

  - `connect-src 'self' wss://<host>`: the LiveView websocket. CSP3 browsers match `wss` to
    `'self'`, but older Safari implementations did not, so the explicit scheme is belt and
    suspenders. `<host>` is the request's own host - nothing cross-origin is ever allowed.
  - `style-src 'self' 'unsafe-inline'`: compiled Tailwind/daisyUI is a same-origin
    stylesheet; `'unsafe-inline'` covers style attributes LiveView's JS sets while patching
    (the topbar progress). Inline *styles* are not an execution primitive, so this is the
    low-risk half of CSP.
  - `img-src 'self' data:`: heroicons render as CSS masks with inline data URIs.
  - `frame-ancestors 'none'`, `object-src 'none'`, `base-uri`/`form-action` `'self'`:
    clickjacking and injection hardening. There is no `x-frame-options` in Phoenix 1.8's
    default header set anymore; `frame-ancestors` is its replacement.

  `put_secure_browser_headers/2` still supplies the rest of the baseline
  (`x-content-type-options`, `referrer-policy`, ...) and merges this map over its defaults.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    conn = Plug.Conn.assign(conn, :csp_nonce, nonce)

    Phoenix.Controller.put_secure_browser_headers(conn, %{
      "content-security-policy" => policy(host_header(conn), nonce)
    })
  end

  defp host_header(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host] -> host
      [] -> conn.host
    end
  end

  defp policy(host, nonce) do
    "default-src 'self'; " <>
      "script-src 'self' 'nonce-#{nonce}'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data:; " <>
      "font-src 'self'; " <>
      "connect-src 'self' wss://#{host}; " <>
      "frame-ancestors 'none'; " <>
      "base-uri 'self'; form-action 'self'; object-src 'none'"
  end
end
