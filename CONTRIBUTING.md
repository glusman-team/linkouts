# Contributing

## What this is

linkouts gives every edge in a Translator knowledge graph a public, human-readable page: the
sentence the edge asserts, the evidence behind it, where it came from, and how it changed across
KG releases. It is live at https://linkouts.skyelanegoetz.com.

## What we want from contributors

- **KG display configs** (the main one). A knowledge graph gets readable pages when it has a
  declarative data file in `kgs/*.exs`. No Elixir functions, no templates, no HTML. Follow
  [docs/pages/add-a-kg.md](docs/pages/add-a-kg.md); it covers generating a starter config from a
  real KGX file, naming it, extending the default config, wording the edge sentence, handling a
  field rename across releases, and validating the result with `cd web && mix linkouts.check`.
  To ask for a graph we do not serve yet, open a **Request a knowledge graph** issue instead of a PR.
- **Small web fixes** in `web/`: a broken page state, a wrong label, a render bug, a missing
  test, a dependency or lint cleanup.
- **Docs** in `docs/pages/` and `docs/adr/`. If you changed behavior, the guide that describes it
  changed too.

Keep the diff small and the behavior change covered by a test. The visible UI text and the HTML
structure are load-bearing (reviewers cite sentences, and the read path is compared against golden
fixtures), so leave them alone unless your PR is specifically about that text.

## What is NOT contributor-facing

- **The Go CLI (`cli/`) is maintainer-only.** It writes to Azure Cosmos DB and needs write
  credentials contributors do not have. Do not open a PR against `cli/` without asking first in an
  issue; the ingestion contract is fixed by `docs/adr/0001-wire-format.md` and enforced by a
  cross-language test.
- **Deployment is maintainer-only.** `Dockerfile`, `fly.toml`, `.github/workflows/deploy.yml`, the
  Cloudflare zone and the origin key are not things a contributor PR should change. See
  [docs/pages/deployment.md](docs/pages/deployment.md) to understand the runtime, not to operate it.

## Dev setup

You need Go, Elixir/OTP 28 and `make`. Everything below is offline: no Azure account, no Cosmos,
no credentials, no request units spent.

```sh
make setup        # one time: hex, rebar, go modules, mix deps, asset binaries
make local-load   # encode a sample KG to tmp/edges.local.ndjson via the CLI file backend
make local-web    # Phoenix on http://localhost:4000 reading that file
```

`make local-load` builds the CLI and loads a local KGX `nodes.ndjson` / `edges.ndjson` pair into a
plain file instead of Cosmos. By default it reads the DAKP sample from `~/Desktop/dakp-latest`;
point `DAKP_DIR`, `DAKP_NODES` and `DAKP_EDGES` at any KGX pair you have on disk. If you have no
local sample, use the fixtures committed in `cli/testdata/dakp` exactly as
[docs/pages/quickstart.md](docs/pages/quickstart.md) shows: load two releases into
`file:/tmp/edges.ndjson`, then run the web app with
`COSMOS_BACKEND=file COSMOS_DOCS=/tmp/edges.ndjson mix phx.server` from `web/`.

## Verify before pushing

```sh
make check
```

`make check` is the full offline gate: format checks, lint (golangci-lint and credo), compile with
warnings as errors, and `make test` (the Go tests with `-race`, the Elixir tests with Cosmos
stubbed, and the KG config validation). It never needs network access or credentials. CI runs it
plus three more targets you can also run locally: `make ex-test-cluster` (two-node cluster proofs),
`make contract-check` (the cross-language test that the Elixir reader agrees with the Go writer,
byte for byte) and `make docs-check` (fails if the generated CLI docs or the ExDoc site are stale).

Narrower loops while you work:

```sh
make ex-test          # Elixir tests only (Cosmos stubbed, no network)
make go-test-fast     # Go tests, skipping the embedded ClickHouse engine extraction
make kgs-check        # validate every kgs/*.exs and render the golden fixtures
cd web && mix linkouts.check   # fastest config feedback, reports every problem at once
make fmt              # gofumpt + mix format
```

`make hooks` installs the prek hooks (fast auto-fixes on commit, the heavy gates on push). Every
hook calls a Makefile target, so hooks, CI and `make check` cannot drift.

## PR conventions

- **Title: a conventional commit.** `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `perf:`,
  `chore:`, for example `feat(kgs): add display config for infores:my-kp`.
- **Small, focused diffs.** One concern per PR. A KG display config is its own PR; do not bundle it
  with a web refactor.
- **Tests for behavior changes.** A fix without the test that would have caught it is not finished.
  A new `kgs/*.exs` needs `make kgs-check` to pass.
- **Say how you verified it.** Put the exact commands you ran and their result in the PR body
  (`.github/PULL_REQUEST_TEMPLATE.md` asks for this).
- **Do not touch `cli/`, deployment files or the visible UI text** unless that is the point of the
  PR.

## Where the details live

- [docs/pages/](docs/pages/) - the read path, storage format, ingestion, deployment, config
  reference, the default display config, and the quickstart.
- [docs/adr/](docs/adr/) - the decisions behind them: the wire format, the verified API surface,
  storage v2, and the cluster-ready read path.
- [SECURITY.md](SECURITY.md) - how secrets are kept out, the origin lockdown, the RU budget split,
  and how to report a vulnerability privately.
