defmodule EdgeLinkoutsWeb.RandomController do
  use EdgeLinkoutsWeb, :controller

  alias EdgeLinkoutsWeb.Edges

  # A controller, not a LiveView: /random must answer with an HTTP 302 so an external
  # link can point at it; a LiveView would render a page instead of redirecting.
  def random(conn, _params) do
    case Edges.fetch_pool() do
      {:ok, [_ | _] = ids} ->
        redirect(conn, to: ~p"/edges/#{Enum.random(ids)}")

      # A missing or empty pool is a broken random link; landing on the home page is
      # strictly better than a 500.
      _ ->
        redirect(conn, to: ~p"/")
    end
  end
end
