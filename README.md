# edge-linkouts

Human-readable pages for individual knowledge-graph edges. Give it an edge UUID and it
shows what the edge asserts, the evidence behind it, where it came from, and how it
changed across KG releases.

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

> Status: built and verified locally. Deployment runs through `deploy.yml` and is
> dormant until the steps in [Deploy](#deploy) are done.

## Quickstart (local, no cloud)

```sh
make setup          # hex/rebar, go modules, mix deps, asset binaries (one time)
make check          # full offline gate: fmt, lint, compile, tests, kgs validation
make local-load     # encode the DAKP sample to tmp/edges.local.ndjson (no Cosmos)
make local-web      # Phoenix on http://localhost:4000 against that file
```

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
| `SECRET_KEY_BASE` | web (prod) | `mix phx.gen.secret` |
| `PHX_HOST` | web (prod) | `linkouts.skyelanegoetz.com` |

## Deploy

Not exercised yet. These are the steps for when you're ready:

1. Create the Fly app: `fly launch --name edge-linkouts --region lax --no-deploy`.
   Azure West US 2 is in Quincy, WA, and Fly has retired `sea`, so `lax` is the
   closest region.
2. Set secrets: `fly secrets set SECRET_KEY_BASE=… COSMOS_PRIMARY_CONNECTION_STRING_R=…`
3. Create the CI token: `fly tokens create deploy -x 90d`, then save it as the GitHub
   repo secret `FLY_API_TOKEN`.
4. Push to `main`. `deploy.yml` runs `flyctl deploy --remote-only`.
5. Set up Cloudflare. Add a CNAME `linkouts` → `edge-linkouts.fly.dev`, proxied, with
   SSL set to Full (strict). Then run `fly certs add linkouts.skyelanegoetz.com`.

## Development

`make help` lists every target. The hooks are managed by prek and run in two stages:
fast auto-fixes on commit, and the heavy gates on push. Install them with `make hooks`.
