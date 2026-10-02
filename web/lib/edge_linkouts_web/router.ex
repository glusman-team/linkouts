defmodule EdgeLinkoutsWeb.Router do
  use EdgeLinkoutsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EdgeLinkoutsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EdgeLinkoutsWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/edges/:id", EdgeLive

    get "/random", RandomController, :random

    # A controller rather than a LiveView: a file download needs a real HTTP response
    # carrying Content-Disposition, which a LiveView cannot produce for a top-level
    # navigation.
    get "/edges/:id/download", EdgeController, :download
  end
end
