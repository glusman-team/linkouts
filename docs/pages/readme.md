# EdgeLinkouts

EdgeLinkouts gives every edge in a Biolink KGX knowledge graph a permanent, human-readable page.

A reviewer who follows a link to `/edges/<uuid>` sees a sentence describing the relationship
("Desflurane is contraindicated for patients with asthma"), links to every identifier involved,
the evidence the knowledge source recorded, and how the edge changed between releases.

## Two programs

- **`linkouts`** (Go, in `cli/`) reads a KG's `nodes.ndjson` and `edges.ndjson`, joins node names
  onto edges with embedded ClickHouse, drops null-like values, and stores one compressed, versioned
  document per edge in Azure Cosmos DB.
- **The web app** (Phoenix LiveView, in `web/`) reads one document by edge id and renders it
  through the KG's display config.

They share one contract: the stored document format in `docs/adr/0001-wire-format.md`, enforced
by a test that has the Elixir reader re-encode the Go writer's output byte for byte.

## Where to start

- [Quickstart](quickstart.md): run everything locally against the committed fixtures, no Azure account.
- [Ingesting a KG](ingest.md): load a real release into Cosmos.
- [Adding a KG](add-a-kg.md): write a display config.
- [Config reference](config-reference.md): every form the config language supports.
- [Storage format](storage-format.md): what is in Cosmos and why.
- [Deployment](deployment.md): Fly.io and Cloudflare.
