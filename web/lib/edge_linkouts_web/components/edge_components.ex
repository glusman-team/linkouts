defmodule EdgeLinkoutsWeb.EdgeComponents do
  @moduledoc """
  Presentation pieces shared by the edge pages.

  Everything here renders *data* with HEEx escaping: `segments/1` walks the
  `EdgeLinkouts.Display.Segment` tuples, so a value from an upstream KG can never become
  markup. The relationship diagram is plain HTML and CSS (no SVG, no JS): names wrap
  instead of being clipped to a box, which is what an SVG text element cannot do.

  Linkouts leave the site, so every rendered link says so: an arrow icon, and prose links
  carry a screen-reader note. Chips carry the resolver host in `title` instead, because
  thirty chips each announcing a sentence would bury the list.
  """

  use EdgeLinkoutsWeb, :html

  alias EdgeLinkouts.Display.Prefixes

  # Field names as a reader knows them. The diff panel shares this table so a field reads the
  # same everywhere; anything unlisted falls back to its underscores turned to spaces, which is
  # still readable and never hides a field.
  @field_labels %{
    "id" => "Edge id",
    "subject" => "Subject identifier",
    "object" => "Object identifier",
    "subject_name" => "Subject name",
    "object_name" => "Object name",
    "original_subject" => "Subject as the source wrote it",
    "original_object" => "Object as the source wrote it",
    "predicate" => "Predicate",
    "category" => "Category",
    "subject_category" => "Subject category",
    "object_category" => "Object category",
    "regulatory_approvals" => "Regulatory approvals",
    "FDA_regulatory_approvals" => "Regulatory approvals",
    "publications" => "Product labels",
    "number_of_cases" => "FAERS case count",
    "clinical_approval_status" => "Clinical approval status",
    "knowledge_level" => "Knowledge level",
    "agent_type" => "Assertion method",
    "disease_context_qualifier" => "Disease context",
    "disease_context_qualifier_name" => "Disease context",
    "sources" => "Knowledge sources",
    "supporting_text" => "Supporting text",
    "has_supporting_studies" => "Supporting studies"
  }

  @doc "A stored field name as a reader knows it."
  def field_label(key), do: Map.get(@field_labels, key, String.replace(key, "_", " "))

  @doc "Rendered linkout segments: text runs and hyperlinks, escaped by the template."
  attr :segments, :list, required: true
  attr :note, :boolean, default: true, doc: "add the screen-reader note to links"

  def segments(assigns) do
    ~H"""
    <.segment :for={segment <- @segments} segment={segment} note={@note} />
    """
  end

  defp segment(%{segment: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  # Emphasis: the primary knowledge source inside a source list, where bold carries the
  # distinction a "(primary)" parenthetical used to spell out.
  defp segment(%{segment: {:strong, inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)

    ~H"""
    <strong class="linkout-strong"><.segments segments={@inner} note={@note} /></strong>
    """
  end

  defp segment(%{segment: {:link, href, label}} = assigns) do
    assigns = assign(assigns, href: href, label: label, host: host_of(href))

    ~H"""
    <a href={@href} class="ext-link" title={@host} target="_blank" rel="noopener noreferrer">{@label}<.icon
      name="hero-arrow-top-right-on-square"
      class="ext-icon"
    /><span :if={@note} class="sr-only"> (opens {@host} in a new tab)</span></a>
    """
  end

  # A labelled fold: one fact (a node's CURIE) behind a chip named for what it holds. Same
  # inline reveal as the list fold below; the button's data-more is the chip label itself,
  # so the toggle restores "curie", and data-less swaps it for "hide" while open.
  defp segment(%{segment: {:fold, label, hidden}} = assigns) do
    assigns = assign(assigns, hidden: hidden, label: label)

    ~H"""
    <span class="linkout-more linkout-fold">
      <button
        type="button"
        class="linkout-more-btn"
        aria-expanded="false"
        data-more={@label}
        data-less="hide"
      >
        {@label}
      </button>
      <span class="linkout-more-rest" hidden><.segments segments={@hidden} note={@note} /></span>
    </span>
    """
  end

  # A list fold: the items beyond the inline cap, revealed in place by a button. A native
  # <details> is block-shaped in some engines and opened a vertical gap inside the paragraph,
  # so the toggle is a plain inline <button> and the rest is an inline <span hidden> — neither
  # can introduce line breaks. assets/js/app.js does the reveal.
  defp segment(%{segment: {:more, hidden}} = assigns) do
    # The payload is [separator, item, separator, item, …], so the item count is half its length.
    assigns = assign(assigns, hidden: hidden, count: div(length(hidden), 2))

    ~H"""
    <span class="linkout-more">
      <button
        type="button"
        class="linkout-more-btn"
        aria-expanded="false"
        data-more={"Show #{@count} more"}
      >
        Show {@count} more
      </button>
      <span class="linkout-more-rest" hidden><.segments segments={@hidden} note={@note} /></span>
    </span>
    """
  end

  @doc """
  Subject card, predicate, object card, as wrapping HTML.

  The legacy SVG diagram clipped names at 24 characters; a relationship about
  "hydrochlorothiazide" deserves its whole name. Cards stack below the predicate on narrow
  screens, where a horizontal arrow would squeeze both boxes to nothing.
  """
  attr :doc, :map, required: true

  def diagram(assigns) do
    doc = assigns.doc

    assigns =
      assigns
      |> assign(:subject_name, node_label(doc, "subject"))
      |> assign(:subject_curie, doc["subject"])
      |> assign(:subject_href, Prefixes.url(doc["subject"]))
      |> assign(:subject_category, category(doc, "subject"))
      |> assign(:object_name, node_label(doc, "object"))
      |> assign(:object_curie, doc["object"])
      |> assign(:object_href, Prefixes.url(doc["object"]))
      |> assign(:object_category, category(doc, "object"))
      |> assign(:predicate, doc["predicate"] || "")
      |> assign(:predicate_label, humanize_predicate(doc["predicate"] || ""))
      |> assign(
        :summary,
        "This relationship: #{node_label(doc, "subject")} (#{doc["subject"]}) " <>
          "#{doc["predicate"]} #{node_label(doc, "object")} (#{doc["object"]})"
      )

    ~H"""
    <section class="edge-diagram" aria-label={@summary}>
      <.node_card
        role="Subject"
        name={@subject_name}
        curie={@subject_curie}
        href={@subject_href}
        category={@subject_category}
      />
      <div class="edge-rel" aria-hidden="true">
        <.icon name="hero-arrow-right" class="edge-rel-arrow" />
        <p class="edge-rel-predicate">{@predicate_label}</p>
        <code class="edge-rel-raw">{@predicate}</code>
      </div>
      <.node_card
        role="Object"
        name={@object_name}
        curie={@object_curie}
        href={@object_href}
        category={@object_category}
      />
    </section>
    """
  end

  attr :role, :string, required: true
  attr :name, :string, required: true
  attr :curie, :string, default: nil
  attr :href, :string, default: nil
  attr :category, :string, default: nil

  defp node_card(assigns) do
    assigns = assign(assigns, :host, host_of(assigns.href))

    ~H"""
    <div class="edge-node">
      <p class="edge-node-role">{@role}</p>
      <p class="edge-node-name">{@name}</p>
      <p :if={@category} class="edge-node-cat">{@category}</p>
      <p :if={@curie} class="edge-node-id">
        <code>{@curie}</code>
        <button type="button" class="copy-btn" data-copy={@curie} aria-label={"Copy #{@curie}"}>
          <.icon name="hero-clipboard" class="size-3.5" />
          <span class="copy-text">Copy</span>
        </button>
        <a
          :if={@href}
          class="ext-link text-sm"
          href={@href}
          title={@host}
          target="_blank"
          rel="noopener noreferrer"
        >
          {@host}<.icon name="hero-arrow-top-right-on-square" class="ext-icon" />
        </a>
      </p>
    </div>
    """
  end

  @doc """
  The stored versions as a timeline: oldest first, each labelled by its release number and
  how many fields that release changed, the selected one marked for assistive tech.
  """
  attr :edge_id, :string, required: true
  attr :history, :list, required: true
  attr :current, :string, required: true

  def version_timeline(assigns) do
    # The latest release is the rightmost pill by construction (history is sorted oldest to
    # newest), so the badge keys off the last step, not a label match against the config:
    # a blob accumulated out of version order still badges the true newest.
    latest_key =
      case List.last(assigns.history) do
        nil -> nil
        step -> step.key
      end

    assigns = assign(assigns, :latest_key, latest_key)

    ~H"""
    <nav aria-label="Stored versions" class="timeline">
      <ol>
        <li :for={step <- @history}>
          <%!-- Before the pill, not inside it: the same chip the home page's pill row uses.
               Reading order is "latest, 1.23.4", so the chip leads its pill on the left. --%>
          <span :if={step.key == @latest_key} class="latest-badge">latest</span>
          <.link
            patch={~p"/edges/#{@edge_id}?version=#{step.key}"}
            class="timeline-step"
            aria-current={step.key == @current && "page"}
          >
            <span class="timeline-label">{step.label}</span>
            <span :if={step.changes} class="count-badge">
              {step.changes} change{if step.changes == 1, do: "", else: "s"}
            </span>
            <span :if={step.changes == 0} class="count-badge">no changes</span>
          </.link>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  The changes between the previous and the selected version, grouped by kind and labelled in
  the reader's vocabulary. Colour never carries the diff alone: every line also shows a
  +/- marker and a visually-hidden word for screen readers.
  """
  attr :prev_key, :string, default: nil
  attr :key_name, :string, default: nil
  attr :diff, :list, default: nil

  def diff_panel(assigns) do
    groups =
      case assigns.diff do
        nil -> []
        diff -> group_changes(diff)
      end

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <section aria-label="Changes from the previous version" class="diff-panel">
      <h2 class="section-title">Changes</h2>
      <%= cond do %>
        <% is_nil(@prev_key) -> %>
          <p>
            This is the oldest stored version; there is nothing earlier to compare it with.
          </p>
        <% is_nil(@diff) -> %>
          <p>The previous version ({@prev_key}) could not be resolved, so no diff is shown.</p>
        <% @diff == [] -> %>
          <p>No changes between {@prev_key} and this version.</p>
        <% true -> %>
          <p class="diff-summary">
            {length(@diff)} field{if length(@diff) == 1, do: "", else: "s"} differ between {@prev_key} and {@key_name} (<span class="diff-line-added">+ added</span>
            / <span class="diff-line-removed">- removed</span>):
          </p>
          <div :for={{title, entries} <- @groups} class="diff-group">
            <h3>{title}</h3>
            <ul>
              <.diff_entry :for={change <- entries} change={change} />
            </ul>
          </div>
      <% end %>
    </section>
    """
  end

  defp group_changes(diff) do
    diff
    |> Enum.group_by(fn
      {:added, _, _} -> "Added fields"
      {:removed, _, _} -> "Removed fields"
      {:changed, _, _, _} -> "Changed values"
      {:list_changed, _, _, _} -> "Changed lists"
    end)
    |> Enum.sort_by(fn {title, _} -> title end)
  end

  defp diff_entry(%{change: {:added, key, new}} = assigns) do
    assigns = assign(assigns, key: key, values: values(new))

    ~H"""
    <li class="diff-line-added">
      <span aria-hidden="true">+</span><span class="sr-only"> added </span>
      <span class="diff-field">{field_label(@key)}</span>
      <code :for={value <- @values}>{value}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:removed, key, old}} = assigns) do
    assigns = assign(assigns, key: key, values: values(old))

    ~H"""
    <li class="diff-line-removed">
      <span aria-hidden="true">-</span><span class="sr-only"> removed </span>
      <span class="diff-field">{field_label(@key)}</span>
      <code :for={value <- @values}>{value}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:changed, key, old, new}} = assigns) do
    assigns = assign(assigns, key: key, olds: values(old), news: values(new))

    ~H"""
    <li class="diff-line-changed">
      <span class="sr-only"> changed </span>
      <span class="diff-field">{field_label(@key)}</span>
      <code :for={value <- @olds} class="diff-old">{value}</code>
      <.icon name="hero-arrow-right" class="diff-arrow" />
      <code :for={value <- @news} class="diff-new">{value}</code>
    </li>
    """
  end

  defp diff_entry(%{change: {:list_changed, key, added, removed}} = assigns) do
    assigns =
      assign(assigns,
        key: key,
        added: Enum.map(added, &pretty/1),
        removed: Enum.map(removed, &pretty/1)
      )

    ~H"""
    <li class="diff-line-changed">
      <span class="diff-field">{field_label(@key)}</span>
      <ul class="diff-list">
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

  defp node_label(doc, field) do
    doc["#{field}_name"] || doc[field] || ""
  end

  defp category(doc, field) do
    case doc["#{field}_category"] do
      [first | _] when is_binary(first) -> humanize_category(first)
      _ -> nil
    end
  end

  # "biolink:SmallMolecule" reads as "Small molecule" once the prefix, the camel humps and
  # the underscores go. The raw CURIE category stays in the document for anyone who needs it.
  defp humanize_category(value) do
    value
    |> humanize_predicate()
    |> String.replace(~r/(?<=[a-z0-9])([A-Z])/, " \\1")
    |> then(fn text -> String.capitalize(text) end)
  end

  # "biolink:applied_to_treat" reads as prose once the prefix and underscores go; the raw
  # predicate stays visible beside it because the exact term is what a curator checks.
  defp humanize_predicate(value) do
    value
    |> String.replace(~r/^biolink:/i, "")
    |> String.replace("_", " ")
  end

  # The resolver's host, so a linkout says where it goes before it is clicked.
  defp host_of(nil), do: nil

  defp host_of(href) do
    case URI.parse(href) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> href
    end
  end

  # Strings print as themselves; everything else keeps its JSON shape, so a nested map in a
  # diff is visibly a nested map rather than a quoted blob.
  defp pretty(value) when is_binary(value), do: value
  defp pretty(value) when is_number(value), do: to_string(value)
  defp pretty(value), do: JSON.encode!(value)

  # A changed list reads as one chip per element; a scalar reads as one chip. A JSON array
  # printed inline is the wall of text the evidence panel was redesigned to avoid.
  defp values(list) when is_list(list), do: Enum.map(list, &pretty/1)
  defp values(value), do: [pretty(value)]
end
