# Security

## Reporting a vulnerability

Use **GitHub private vulnerability reporting** on this repository:
`Settings -> Code security -> Private vulnerability reporting`, then "Report a vulnerability"
from the [Security](https://github.com/glusman-team/linkouts/security) tab. That opens a private
draft advisory visible only to the maintainer.

If you would rather not use GitHub, reach the maintainer through the contact details on their
profile: https://github.com/SkyeAv.

**Do not open a public issue for a leaked secret, a credential, or a vulnerability.** Public issues
are indexed immediately and the exposure is already live by the time anyone reads it. Include: what
you found, the smallest reproduction, whether any real credential is involved, and how urgent you
think it is. Expect an acknowledgement within a few days.

## No secrets in this repository

- Azure Cosmos DB account keys come from the environment (direnv) only. Nothing in the tree holds a
  key value.
- `.envrc` is gitignored. `.envrc.example` is committed and documents **variable names only**; it
  carries no values and inherits the real ones from a parent `~/.envrc`.
- Production secrets live in `fly secrets`, not in the repo and not in CI.
- `gitleaks` runs as a pre-commit hook over every staged change, with the default rule set plus
  project-specific rules in `.gitleaks.toml` for a Cosmos account key inside a connection string
  (`AccountKey=...`) and for a Fly.io API token (`fm2_...`). It is the backstop for a key pasted
  into a file by accident, including a private key file.
- `check-added-large-files` (512 KiB) keeps data dumps and keystores out of history.

If a key ever does land in a commit, treat it as compromised and rotate it in the Azure portal. Do
not rewrite history and call it fixed.

## The web app is read-only

The Phoenix app in `web/` is given **only the Cosmos read-only key**, `COSMOS_PRIMARY_CONNECTION_STRING_R`.
It cannot write, upsert or delete anything. The separate read-write key,
`COSMOS_PRIMARY_CONNECTION_STRING_RW`, is used by the maintainer's ingestion CLI and never reaches
the deployed app: a compromise of the web tier yields reads of already-public data, not mutation of
the store. The read-only boundary is a design decision recorded in
`docs/adr/0002-verified-api-surface.md`.

## Origin lockdown

Fly gives every app a `edge-linkouts.fly.dev` hostname that cannot be removed while the app exists,
and Cloudflare reaches the origin through it. Without a check, anyone could bypass the CDN (and its
DDoS protection) by hitting that hostname directly and spend the Cosmos RU budget unobserved.

So in production every request must carry an `X-Origin-Key` header, compared against the value of
`X_ORIGIN_KEY`:

- The check is `web/lib/edge_linkouts_web/origin_check.ex`. It compares with
  `Plug.Crypto.secure_compare/2`, which is constant time, because the header is a shared secret and
  a plain `==` would leak it byte by byte through a timing oracle.
- A missing or wrong header gets a bare `403` before any route, LiveView or store read runs. The
  plug sits in the endpoint ahead of the parser, session and router.
- `GET /healthz` is exempt: `web/lib/edge_linkouts_web/health_check.ex` runs first and answers `200
  ok` without touching anything, so Fly's direct, header-less machine checks pass.
- Cloudflare is the only intended client. A Transform Rule on the zone adds the header to every
  proxied request, so browsers never see it or need it.
- The key is read from the environment **once at boot** (`web/config/runtime.exs`) into
  `config :edge_linkouts, :origin_check_key`, not per request. Unset means the check is inert, so
  local development and the test suite are unaffected even if a stray `X_ORIGIN_KEY` leaks into a
  developer's shell.

The origin key itself is a secret and lives only in `fly secrets` and in the Cloudflare zone
configuration. It is not in the repo.

## RU budget isolation

The Cosmos account runs on the 1000 RU/s free tier, and the budget is split so that neither side
can starve the other:

- The web app is hard-capped at `RU_BUDGET_WEB=150` RU/s (set in `fly.toml`). A traffic spike,
  a crawler, or a liveview fan-out cannot consume the ingestion budget.
- The maintainer's CLI is capped at `RU_BUDGET_CLI=750` RU/s. A large load cannot starve the read
  path.
- The remaining 10% stays headroom for the Azure portal and for retries.

Both limits are enforced client side by `web/lib/edge_linkouts/rate_limiter.ex` and the CLI's
equivalent, so the cap holds regardless of what the caller asks for. Reads are additionally
de-duplicated per page view (`web/lib/edge_linkouts/dedupe.ex`) and served from a TTL cache, which
is what keeps 150 RU/s sufficient.

## Other notes

- The app has no form POST routes; events travel on the LiveView socket. The body parser accepts
  only `urlencoded` with a 64 KB limit, so accepted input stays minimal.
- Dependencies are tracked by Dependabot (`.github/dependabot.yml`) for GitHub Actions, Go modules
  and Hex.
- `make check` is fully offline and needs no credentials, so a contributor can verify a change
  without any access to the production account.
