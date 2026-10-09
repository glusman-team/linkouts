# Deployment

The app runs on Fly.io behind Cloudflare and reads from Azure Cosmos DB on the free tier
(1000 RU/s, 25 GB).

Everything in this section needs credentials and costs or changes something real. None of it runs
in CI or from `make check`.

## Budget

The free tier's 1000 RU/s is shared. The CLI gets the burst budget it needs for ingestion,
750 RU/s by default; the web app gets 150 RU/s (`RU_BUDGET_CLI`, `RU_BUDGET_WEB`), and the
remaining 10% is headroom for the portal and retries. Crawler defence is a Cloudflare
rate-limiting rule on the hostname, not the RU budget. Both apps pace themselves using the
charge Cosmos actually reports, not an estimate.

Measure before you size anything:

```sh
cli/bin/linkouts probe --n 20
cli/bin/linkouts status --check-pools
```

`status` is the check the Azure portal does not give: documents stored, graphs and releases with a
random pool, the pool sizes against what the index claims, and the container's indexing policy.
Both `linkouts status` and the web app assume the policy is `none` — no indexes at all, every read
a point read by id — so a policy that says anything else means someone changed it in the portal and
is paying index storage and write RUs for queries this app never issues.

What a request costs: an edge page is one point read (1 RU for a document up to 1 KB). The root
page is one point read of the pool index. `/random` is the index plus one release's pool, and
`/<slug>/random?version=<label>` is one pool read and nothing else; both are cached in the node for
fifteen minutes, so a thousand randoms cost about two reads.

## Health and liveness

`/healthz` is the liveness endpoint: it answers `200 ok` without touching Cosmos and is the one
route exempt from the origin-key check, because Fly's own probes cannot carry the key.
`fly.toml` wires it as the HTTP service check (10 s interval, 2 s timeout, 10 s grace). It says
"the node can serve", not "Cosmos is reachable" - a Cosmos outage shows up as page errors, not as
a failing health check, so the machine is never killed for a dependency it cannot fix.

## Replacing stored data

Nothing reads a document written by an older format: it is refused by schema rather than
mis-decoded. The migration is a reload into a NEW container, then an atomic flip. Stage locally
(zero RU), mirror, verify, flip, drop the old container:

```sh
# 1. Stage the release(s) into a local file store in the current format (zero RU).
cli/bin/linkouts --store file:/tmp/staged/edges.ndjson load <kg>-<version>   --nodes ...ndjson --edges ...ndjson --dict web/priv/zstd/<kg>.<dictid>.dict

# 2. Create the target container (indexing "none", partition key /id) and mirror into it.
COSMOS_CONTAINER=edges_v2 cli/bin/linkouts init
COSMOS_CONTAINER=edges_v2 cli/bin/linkouts push --store file:/tmp/staged/edges.ndjson --dry-run
COSMOS_CONTAINER=edges_v2 cli/bin/linkouts push --store file:/tmp/staged/edges.ndjson --yes

# 3. Verify cost and contents against the new container before anything reads it.
COSMOS_CONTAINER=edges_v2 cli/bin/linkouts probe --n 20
COSMOS_CONTAINER=edges_v2 cli/bin/linkouts status --check-pools

# 4. Flip the running app (one secret change redeploys the machine).
fly secrets set COSMOS_CONTAINER=edges_v2

# 5. Once the site is verified on the new container, drop the old one.
COSMOS_CONTAINER=edges cli/bin/linkouts purge --drop-container --yes
```

`push` skips documents that are already identical and replaces only changed ones, so a re-run
after an interruption is cheap. `purge --key <slug>-<version>` removes one release from the edge
documents that hold it (deleting its pool and index entry, materialising any version other deltas
depend on first); `purge --all` wipes a container's documents; `purge --drop-container` deletes
the container itself.

## Order of operations

1. **Load data.** `linkouts init`, then `linkouts load` for each release. See [Ingesting a KG](ingest.md).
2. **Create the Fly app.**
   ```sh
   fly launch --name edge-linkouts --region lax --no-deploy
   ```
   `lax` is the closest Fly region to Azure West US 2 (Quincy, WA). Check with `fly platform regions`.
3. **Set secrets.** The web app gets the **read-only** key. The read-write key belongs to the CLI
   and must never reach the server.
   ```sh
   fly secrets set SECRET_KEY_BASE=... COSMOS_ENDPOINT=... COSMOS_DB=edge_linkouts \
     COSMOS_CONTAINER=edges COSMOS_READ_ONLY_KEY=... RU_BUDGET_WEB=150 \
     PHX_HOST=linkouts.skyelanegoetz.com X_ORIGIN_KEY=...
   ```
   `COSMOS_READ_ONLY_KEY` and `COSMOS_PRIMARY_CONNECTION_STRING_R` are both accepted (the
   connection string carries the endpoint and key together); set one. `X_ORIGIN_KEY` is the
   origin-lockdown secret every request except `/healthz` must present as `X-Origin-Key`
   (Cloudflare adds it with a Transform Rule); without it the app refuses every request.
   A production boot without a Cosmos key fails at startup with a message saying which variable is
   missing. It does not start and serve 404s.
4. **Deploy.** `fly deploy`, or push to `main`. `deploy.yml` runs `flyctl deploy --remote-only` for
   changes under `web/` or `kgs/`.
5. **DNS.** In Cloudflare, add a CNAME `linkouts` → `edge-linkouts.fly.dev`, proxied, with SSL mode
   **Full (strict)**. LiveView needs WebSocket upgrades, and Flexible SSL breaks them. Then:
   ```sh
   fly certs add linkouts.skyelanegoetz.com
   ```

## Clustering (inert at one machine)

The app is cluster-ready but runs one machine, where every cluster path is a no-op: the
partitioned cache's ring holds only this node, and `CLUSTER_QUERY` resolves to the machine's own
address. `fly.toml` already sets `CLUSTER_QUERY=edge-linkouts.internal`; `web/rel/env.sh.eex`
names nodes `<app>@<fly-private-ip>` over `inet6_tcp` when `FLY_PRIVATE_IP` is present. To scale
out, the whole runbook is two commands (see `docs/adr/0004-clustering.md`):

```sh
fly secrets set RELEASE_COOKIE=<random>   # releases read it natively at boot
fly scale count 2
```

Node discovery (libcluster DNSPoll), the ring (nebulex_distributed Partitioned), owner-routed
read coalescing and the per-node RU budget split (`RU_BUDGET_WEB / live node count`) all follow
automatically. The RU total stays at `RU_BUDGET_WEB` regardless of node count.

## If you trained a dictionary

The web app has to ship with the same dictionary file that `load --dict` used. Each document
records the dictionary id it was written with. A mismatch is reported as an error naming both ids,
so the cause is clear, but every page for those edges fails until the right file is deployed.
