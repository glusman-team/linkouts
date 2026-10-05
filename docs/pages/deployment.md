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

## Replacing stored data

Nothing reads a document written by an older format: it is refused by schema rather than
mis-decoded. The migration is a reload, and the old documents go away with

```sh
cli/bin/linkouts purge --all --yes      # or --key <slug>-<version> for one release
```

A `--key` purge removes one release from the edge documents that hold it, deletes its pool and
drops its index entry, materialising any version other deltas depend on first. `--all` wipes the
store, including the reserved documents.

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
     PHX_HOST=linkouts.skyelanegoetz.com
   ```
   A production boot without a Cosmos key fails at startup with a message saying which variable is
   missing. It does not start and serve 404s.
4. **Deploy.** `fly deploy`, or push to `main`. `deploy.yml` runs `flyctl deploy --remote-only` for
   changes under `web/` or `kgs/`.
5. **DNS.** In Cloudflare, add a CNAME `linkouts` → `edge-linkouts.fly.dev`, proxied, with SSL mode
   **Full (strict)**. LiveView needs WebSocket upgrades, and Flexible SSL breaks them. Then:
   ```sh
   fly certs add linkouts.skyelanegoetz.com
   ```

## If you trained a dictionary

The web app has to ship with the same dictionary file that `load --dict` used. Each document
records the dictionary id it was written with. A mismatch is reported as an error naming both ids,
so the cause is clear, but every page for those edges fails until the right file is deployed.
