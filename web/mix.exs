defmodule EdgeLinkouts.MixProject do
  use Mix.Project

  def project do
    [
      app: :edge_linkouts,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EdgeLinkouts.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      # Cosmos point reads. Req was rejected: it hard-depends on jason, and Phoenix's
      # json_library is the built-in JSON module here.
      {:finch, "~> 0.24"},
      # Validates kgs/*.exs against the display-config schema.
      {:nimble_options, "~> 1.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:bandit, "~> 1.5"},
      # Deliberately absent: jason (built-in JSON), telemetry_metrics/poller (no dashboard),
      # dns_cluster (no clustering), swoosh/req/gettext/ecto (see PLAN.md).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.38", only: :test},
      # Test-only exception to "no NIFs": lazy_html wraps the Lexbor C library. LiveView 1.2's
      # Phoenix.LiveViewTest hard-requires it (test/dom.ex raises without it), and there is no
      # pure-Erlang alternative. It is never compiled into the release. Without it the
      # "?version= does not re-read" guarantee could not be tested, because that needs a live
      # LiveView process.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.2", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind edge_linkouts", "esbuild edge_linkouts"],
      "assets.deploy": [
        "tailwind edge_linkouts --minify",
        "esbuild edge_linkouts --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
