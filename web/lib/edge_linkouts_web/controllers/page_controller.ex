defmodule EdgeLinkoutsWeb.PageController do
  use EdgeLinkoutsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
