# linkouts

Human-readable pages for individual knowledge-graph edges. Give it an edge UUID and it
shows what the edge asserts, the evidence behind it, where it came from, and how it
changed across KG releases.

Live: https://linkouts.skyelanegoetz.com (currently serving `infores:drugapprovals-kp`
releases 1.23.3 and 1.23.4).

- **`cli/`**: `linkouts`, a Go CLI. It reads KGX `nodes.ndjson` and `edges.ndjson`,
  joins node names and categories onto edges using an embedded ClickHouse engine (chDB),
  compresses each edge's versions into a single zstd blob, and writes them to Azure
  Cosmos DB through one rate-limited output.
- **`web/`**: a minimal Phoenix LiveView app. `/` lists every graph in the store with a pill
  per release, `/edges/:uuid` renders one edge with a per-KG-version toggle and a diff view,
  and `/random`, `/<kg>/random` and `/<kg>/random?version=<label>` pick a random relationship
  from the whole store, one graph, or one release.
- **`kgs/`**: declarative `.exs` display configs. Adding a KG means adding a data
  file, not writing code.
- **`docs/`**: ExDoc guides plus the generated CLI reference.

> Status: live. `deploy.yml` deploys every push to `main` that touches `web/`, `kgs/`,
> `Dockerfile` or `fly.toml`. The runbook (secrets, DNS, cutover, clustering) is
> [docs/pages/deployment.md](docs/pages/deployment.md).

## Architecture

```
KGX release (nodes.ndjson + edges.ndjson)
        |
        v
  cli/ linkouts  -- joins node data onto edges with an embedded ClickHouse (chDB),
        |           compresses every version of an edge into one zstd blob against a
        |           trained dictionary, writes one document per edge
        v
  Azure Cosmos DB  -- container partitioned on /id, indexing policy "none",
        |              every read is a point read by id (1 RU up to 1 KB)
        v
  web/ Phoenix LiveView  -- decodes the blob, renders the edge with a per-release
        |                    toggle and diff; kgs/*.exs decide what each KG shows
        v
  Cloudflare -> Fly.io (one machine, cluster-ready) -> browser
```

The read path never queries Cosmos: it point-reads by id, coalesces concurrent reads of
the same id, caches results per node, and enforces a strict RU budget
(`RU_BUDGET_WEB`) so traffic can never starve ingestion. Details:
[docs/pages/storage-format.md](docs/pages/storage-format.md) and
[docs/adr/](docs/adr/).

## Quickstart (local, no cloud)

```sh
make setup          # hex/rebar, go modules, mix deps, asset binaries (one time)
make check          # full offline gate: fmt, lint, compile, tests, kgs validation
make local-load     # encode the DAKP sample to tmp/edges.local.ndjson (no Cosmos)
make local-web      # Phoenix on http://localhost:4000 against that file
```

Contributors: [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, what we want (KG display
configs in `kgs/`, small web fixes, docs) and what is maintainer-only (the CLI and
deployment). Security reports go through
[SECURITY.md](SECURITY.md), not a public issue.

## Loading a KG into Cosmos

```sh
linkouts init                                   # db + container + indexing policy (idempotent)
linkouts probe --n 20                           # measure real RU per create/read/upsert
linkouts status --check-pools                   # what is stored, and what it costs to read
linkouts load --nodes kg_nodes_v1.2.3.ndjson --edges kg_edges_v1.2.3.ndjson
```

The `--kg` and `--version` values are inferred from Tablassert filenames. To set the
version key explicitly, pass the canonical infores form, `--key infores:my-kp-1.2.3`; the
name without the prefix (`my-kp`) is the slug used in URLs and stored on documents.
`linkouts purge --key my-kp-1.2.3` removes one release and `purge --all` wipes the store.
Writes are capped at `RU_BUDGET_CLI` (750 RU/s by default, 75% of the free tier; the web
app gets 15%, 10% stays headroom). Full flag
reference: `docs/cli/`.

## Configuration

Secrets come from direnv and are never stored in the repo. This repo's `.envrc` is
gitignored. See `.envrc.example` for every variable.

| variable | used by | notes |
|---|---|---|
| `COSMOS_PRIMARY_CONNECTION_STRING_RW` | CLI | `AccountEndpoint=…;AccountKey=…;` read-write |
| `COSMOS_PRIMARY_CONNECTION_STRING_R` | web | read-only key |
| `COSMOS_DB`, `COSMOS_CONTAINER` | both | default `edge_linkouts` / `edges` |
| `RU_BUDGET_CLI`, `RU_BUDGET_WEB` | CLI / web | default 750 / 150 (75% / 15% of the free tier) |
| `DEDUPE_TTL_MS`, `POOL_TTL_MS` | web | edge / pool cache TTLs (default 30000 / 900000) |
| `CHDB_CACHE_DIR` | CLI | where the embedded ClickHouse engine is extracted |
| `X_ORIGIN_KEY` | web | origin lockdown: every request except `/healthz` must carry it as `X-Origin-Key` (Cloudflare sets it) |
| `SECRET_KEY_BASE` | web (prod) | `mix phx.gen.secret` |
| `PHX_HOST` | web (prod) | `linkouts.skyelanegoetz.com` |

## Deploy

Deployed and live; `deploy.yml` runs `flyctl deploy --remote-only` on every push to
`main` that touches `web/`, `kgs/`, `Dockerfile`, `fly.toml` or the workflow itself.
The full runbook (first-time app creation, secrets, Cloudflare/DNS, the storage cutover,
clustering env vars) is [docs/pages/deployment.md](docs/pages/deployment.md).

## Development

`make help` lists every target. The hooks are managed by prek and run in two stages:
fast auto-fixes on commit, and the heavy gates on push. Install them with `make hooks`.
