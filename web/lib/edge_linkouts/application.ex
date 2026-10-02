defmodule EdgeLinkouts.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: EdgeLinkouts.PubSub},
        # One connection pool for Cosmos point reads (see EdgeLinkouts.Cosmos.Finch).
        {Finch, name: EdgeLinkouts.Cosmos.Finch, pools: %{:default => [size: 16, count: 1]}},
        # Read path support: file backend (dev), RU budget, in-flight read coalescing.
        EdgeLinkouts.Cosmos.File,
        EdgeLinkouts.RateLimiter,
        EdgeLinkouts.Dedupe,
        # Start to serve requests, typically the last entry
        EdgeLinkoutsWeb.Endpoint
      ] ++ test_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EdgeLinkouts.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The in-memory Cosmos fake is programmable per test, so it runs only in the test env
  # (config :edge_linkouts, :start_cosmos_fake in config/test.exs).
  defp test_children do
    if Application.get_env(:edge_linkouts, :start_cosmos_fake, false) do
      [EdgeLinkouts.Cosmos.Fake]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EdgeLinkoutsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
