defmodule EdgeLinkoutsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality used by your application.
  """
  use EdgeLinkoutsWeb, :html

  # Embed all files in layouts/* within this module.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout: the site header and the main landmark every page renders into.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300 px-4 py-3 sm:px-6 lg:px-8">
      <nav aria-label="Site" class="mx-auto flex max-w-4xl items-center justify-between gap-4">
        <.link href={~p"/"} class="text-base font-bold tracking-tight">EdgeLinkouts</.link>
        <ul class="flex items-center gap-4 text-sm">
          <li>
            <.link class="link link-hover" href={~p"/"}>Knowledge graphs</.link>
          </li>
          <li>
            <.link class="link link-hover" href={~p"/random"}>Random relationship</.link>
          </li>
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </nav>
    </header>

    <main class="mx-auto w-full max-w-4xl px-4 py-10 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  # Two-state dark-mode toggle. The button carries phx-hook="Theme" (assets/js/app.js):
  # clicking flips data-theme on <html> and persists it in localStorage; with nothing
  # stored the page follows prefers-color-scheme.
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      id="theme-toggle"
      phx-hook="Theme"
      aria-label="Toggle dark mode"
      class="btn btn-ghost btn-sm"
    >
      <.icon name="hero-moon-micro" class="size-4 dark:hidden" />
      <.icon name="hero-sun-micro" class="hidden size-4 dark:block" />
    </button>
    """
  end
end
