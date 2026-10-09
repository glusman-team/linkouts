defmodule EdgeLinkoutsDocs.MixProject do
  @moduledoc """
  The documentation site, as its own tiny project.

  Kept separate from `web/` so ExDoc is not a dependency of the deployed app, and so the site can
  mix hand-written guides, the generated CLI reference and the API docs of the display modules in
  one build. ExDoc over mkdocs: no Python toolchain in a Go and Elixir repo, and the config
  language being documented is Elixir.
  """
  use Mix.Project

  def project do
    [
      app: :edge_linkouts_docs,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps(),
      elixirc_paths: ["lib"],
      # `mix site`, not `mix docs`: see Mix.Tasks.Site for why the API section needs it.
      aliases: [docs: "site"],
      name: "EdgeLinkouts",
      source_url: "https://github.com/glusman-team/linkouts",
      docs: docs()
    ]
  end

  def application, do: []

  defp deps do
    [
      # The app is a path dependency so its moduledocs are the API reference. `runtime: false`
      # because the docs build never starts it.
      {:edge_linkouts, path: "../web", runtime: false},
      {:ex_doc, "~> 0.38", runtime: false}
    ]
  end

  defp docs do
    cli_pages = Path.wildcard("cli/*.md") |> Enum.sort()
    adr_pages = Path.wildcard("adr/*.md") |> Enum.sort()

    [
      main: "readme",
      output: "doc",
      extras:
        [
          {"pages/readme.md", [title: "Overview"]},
          "pages/quickstart.md",
          "pages/ingest.md",
          "pages/add-a-kg.md",
          "pages/config-reference.md",
          "pages/the-default-config.md",
          "pages/storage-format.md",
          "pages/deployment.md"
        ] ++ adr_pages ++ cli_pages,
      groups_for_extras: [
        Guides: ~r{pages/},
        Decisions: ~r{adr/},
        "CLI reference": ~r{cli/}
      ],
      # The API section documents what a config author or contributor touches. The web layer and
      # the transport modules are implementation, not interface.
      filter_modules: fn module, _meta ->
        name = inspect(module)

        # The read path is documented as a unit: the Cosmos behaviour points readers at its
        # backends, and the HTTP backend at the rate limiter and dedupe. Leaving any of them out
        # produces dangling references, and they answer "what does a page view cost?".
        String.starts_with?(name, "EdgeLinkouts.Display") or
          String.starts_with?(name, "EdgeLinkouts.Cosmos") or
          name in [
            "EdgeLinkouts.Codec",
            "EdgeLinkouts.Dicts",
            "EdgeLinkouts.RateLimiter",
            "EdgeLinkouts.Cache",
            "EdgeLinkouts.Cluster",
            "EdgeLinkouts.Dedupe",
            "Mix.Tasks.Linkouts.Check"
          ]
      end,
      groups_for_modules: [
        "Display configs": [~r/EdgeLinkouts\.Display/],
        Storage: [EdgeLinkouts.Codec, EdgeLinkouts.Dicts],
        "Read path": [
          ~r/EdgeLinkouts\.Cosmos/,
          EdgeLinkouts.RateLimiter,
          EdgeLinkouts.Cache,
          EdgeLinkouts.Cluster,
          EdgeLinkouts.Dedupe
        ],
        Tooling: [Mix.Tasks.Linkouts.Check]
      ],
      skip_undefined_reference_warnings_on: cli_pages ++ adr_pages
    ]
  end
end
