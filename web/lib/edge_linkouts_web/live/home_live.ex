defmodule EdgeLinkoutsWeb.HomeLive do
  @moduledoc """
  The index page: one card per knowledge graph with a display config.

  It reads configs, not data: nothing here touches Cosmos, so the page renders with an
  empty store and never spends RU budget.
  """

  use EdgeLinkoutsWeb, :live_view

  alias EdgeLinkouts.Display

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, kgs: Display.configs(), page_title: "Knowledge graphs")}
  end
end
