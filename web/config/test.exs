import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :edge_linkouts, EdgeLinkoutsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "dev-only-not-a-secret-dev-only-not-a-secret-dev-only-not-a-secret-dev-only-not-a-secret-",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests never touch the network: the Fake is the configured backend and the supervision
# tree starts it (programmable documents, failures, latency, call log). The File backend
# instance is pointed at the committed contract fixtures so tests can exercise it too.
config :edge_linkouts,
  cosmos_backend: EdgeLinkouts.Cosmos.Fake,
  start_cosmos_fake: true,
  cosmos_file: Path.expand("../test/fixtures/contract/docs.ndjson", __DIR__)
