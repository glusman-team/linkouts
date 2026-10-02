defmodule EdgeLinkoutsWeb.EdgeComponents do
  @moduledoc """
  Presentation pieces shared by the edge pages.

  Everything here renders *data* with HEEx escaping: `segments/1` walks the
  `EdgeLinkouts.Display.Segment` tuples, so a value from an upstream KG can never become
  markup. The SVG diagram is plain inline HEEx with no JS dependency and degrades to its
  `<title>`/`aria-label` text without CSS or SVG support.
  """

  use EdgeLinkoutsWeb, :html

  alias EdgeLinkouts.Display.Prefixes

  @max_box_label 24

  @doc "Rendered linkout segments: text runs and hyperlinks, escaped by the template."
  attr :segments, :list, required: true

  def segments(assigns) do
    ~H"""
    <.segment :for={segment <- @segments} segment={segment} />
    """
  end

  defp segment(%{segment: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp segment(%{segment: {:link, href, label}} = assigns) do
    assigns = assign(assigns, href: href, label: label)
    ~H"<a href={@href}>{@label}</a>"
  end

  @doc """
  Subject box -> predicate-labelled arrow -> object box, as inline SVG.

  Boxes show the node name and its CURIE and link to the same resolver URLs the sentence
  uses. `role="img"` plus the aria-label summary carry the full relationship for screen
  readers and non-SVG readers alike.
  """
  attr :doc, :map, required: true

  def diagram(assigns) do
    doc = assigns.doc

    assigns =
      assigns
      |> assign(:subject_name, node_label(doc, "subject"))
      |> assign(:subject_curie, doc["subject"])
      |> assign(:subject_href, Prefixes.url(doc["subject"]))
      |> assign(:object_name, node_label(doc, "object"))
      |> assign(:object_curie, doc["object"])
      |> assign(:object_href, Prefixes.url(doc["object"]))
      |> assign(:predicate, doc["predicate"] || "")
      |> assign(
        :summary,
        "Diagram of this relationship: #{node_label(doc, "subject")} (#{doc["subject"]}) " <>
          "#{doc["predicate"]} #{node_label(doc, "object")} (#{doc["object"]})"
      )

    ~H"""
    <svg viewBox="0 0 640 170" role="img" aria-label={@summary} class="edge-diagram not-prose">
      <title>{@summary}</title>
      <defs>
        <marker
          id="edge-diagram-arrow"
          markerWidth="10"
          markerHeight="8"
          refX="9"
          refY="4"
          orient="auto"
        >
          <path d="M0,0 L0,8 L10,4 z" class="edge-diagram-arrow" />
        </marker>
      </defs>

      <a href={@subject_href}>
        <rect x="10" y="45" width="210" height="80" rx="10" class="edge-diagram-box" />
        <text x="115" y="80" text-anchor="middle" class="edge-diagram-name">
          {shorten(@subject_name)}
        </text>
        <text x="115" y="105" text-anchor="middle" class="edge-diagram-curie">{@subject_curie}</text>
      </a>

      <line
        x1="225"
        y1="85"
        x2="412"
        y2="85"
        marker-end="url(#edge-diagram-arrow)"
        class="edge-diagram-line"
      />
      <text x="320" y="70" text-anchor="middle" class="edge-diagram-predicate">
        {shorten(@predicate, 34)}
      </text>

      <a href={@object_href}>
        <rect x="420" y="45" width="210" height="80" rx="10" class="edge-diagram-box" />
        <text x="525" y="80" text-anchor="middle" class="edge-diagram-name">
          {shorten(@object_name)}
        </text>
        <text x="525" y="105" text-anchor="middle" class="edge-diagram-curie">{@object_curie}</text>
      </a>
    </svg>
    """
  end

  defp node_label(doc, field) do
    doc["#{field}_name"] || doc[field] || ""
  end

  # SVG text does not wrap or clip, so overlong labels are truncated for the diagram
  # only; the full name is always in the sentence, the title, and the aria-label.
  defp shorten(text, max \\ @max_box_label)

  defp shorten(text, max) when byte_size(text) <= max, do: text

  defp shorten(text, max) do
    "#{String.slice(text, 0, max - 1)}..."
  end

  @doc "Version switcher: every stored version, current one marked for assistive tech."
  attr :edge_id, :string, required: true
  attr :versions, :list, required: true
  attr :current, :string, required: true

  def version_switcher(assigns) do
    ~H"""
    <nav aria-label="Stored versions">
      <ul class="flex flex-wrap gap-2">
        <li :for={version <- @versions}>
          <.link
            patch={~p"/edges/#{@edge_id}?version=#{version}"}
            class="btn btn-sm btn-outline"
            aria-current={version == @current && "page"}
          >
            {version}
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  @doc """
  The changes between the previous and the selected version, or an explicit "nothing
  changed" line. Colour never carries the diff alone: every line also shows a +/-
  marker and a visually-hidden word for screen readers.
  """
  attr :prev_key, :string, default: nil
  attr :diff, :list, default: nil

  def diff_panel(assigns) do
    ~H"""
    <section aria-label="Changes from the previous version">
      <h2 class="text-lg font-semibold">Changes</h2>
      <%= cond do %>
        <% is_nil(@prev_key) -> %>
          <p>This is the oldest stored version; there is nothing earlier to compare it with.</p>
        <% is_nil(@diff) -> %>
          <p>The previous version ({@prev_key}) could not be resolved, so no diff is shown.</p>
        <% @diff == [] -> %>
          <p>No changes between {@prev_key} and this version.</p>
        <% true -> %>
          <p>
            Changes from {@prev_key} to this version
            (<span class="diff-line-added">+ added</span>
            / <span class="diff-line-removed">- removed</span>):
          </p>
          <ul class="not-prose space-y-1 font-mono text-sm">
            <.diff_entry :for={change <- @diff} change={change} />
          </ul>
      <% end %>
    </section>
    """
  end

  defp diff_entry(%{change: {:added, key, new}} = assigns) do
    assigns = assign(assigns, key: key, json: encode(new))

    ~H"""
    <li class="diff-line-added">
      <span aria-hidden="true">+</span><span class="sr-only"> added </span>
      <strong>{@key}</strong>: <code>{@json}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:removed, key, old}} = assigns) do
    assigns = assign(assigns, key: key, json: encode(old))

    ~H"""
    <li class="diff-line-removed">
      <span aria-hidden="true">-</span><span class="sr-only"> removed </span>
      <strong>{@key}</strong>: <code>{@json}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:changed, key, old, new}} = assigns) do
    assigns = assign(assigns, key: key, old: encode(old), new: encode(new))

    ~H"""
    <li class="diff-line-changed">
      <span class="sr-only"> changed </span>
      <strong>{@key}</strong>: <code>{@old}</code> -> <code>{@new}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:list_changed, key, added, removed}} = assigns) do
    assigns =
      assign(assigns,
        key: key,
        added: Enum.map(added, &encode/1),
        removed: Enum.map(removed, &encode/1)
      )

    ~H"""
    <li class="diff-line-changed">
      <strong>{@key}</strong>:
      <ul>
        <li :for={item <- @added} class="diff-line-added">
          <span aria-hidden="true">+</span><span class="sr-only"> added </span><code>{item}</code>
        </li>
        <li :for={item <- @removed} class="diff-line-removed">
          <span aria-hidden="true">-</span><span class="sr-only"> removed </span><code>{item}</code>
        </li>
      </ul>
    </li>
    """
  end

  defp encode(value), do: JSON.encode!(value)

  @doc """
  Fallback rendering for a blob whose version key has no display config: the raw KGX
  fields, so an unmapped knowledge graph still renders instead of a 500.
  """
  attr :doc, :map, required: true

  def raw_doc(assigns) do
    assigns = assign(assigns, fields: assigns.doc |> Map.to_list() |> Enum.sort())

    ~H"""
    <p class="text-sm opacity-80">
      This knowledge graph has no display configuration, so the stored fields are shown as-is.
    </p>
    <dl>
      <div :for={{key, value} <- @fields} class="py-1">
        <dt class="font-semibold">{key}</dt>
        <dd><code>{JSON.encode!(value)}</code></dd>
      </div>
    </dl>
    """
  end
end
