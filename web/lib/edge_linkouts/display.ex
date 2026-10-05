defmodule EdgeLinkouts.Display do
  @moduledoc """
  Renders a resolved edge document through its KG's declarative display config.

  Configs are loaded at compile time from `kgs/*.exs` and validated then, so a malformed config
  fails the build rather than a page view. `@external_resource` on each loaded file means editing a
  config in dev recompiles the app — the loop a curator actually needs when tuning wording.

  The output is always `[Segment.t()]`, never HTML: templates escape, so a value from an upstream
  KG cannot inject markup. See `EdgeLinkouts.Display.Segment`.
  """

  alias EdgeLinkouts.Display.{Config, Segment, Value}

  # Three levels up from web/lib/edge_linkouts to the repo root, where kgs/ lives.
  # (Display.Prefixes needs four: it is one directory deeper.)
  @kgs_dir Path.expand("../../../kgs", __DIR__)

  # Validating here means a bad config fails the build with the list of problems. Doing it in the
  # comprehension body via an anonymous function because a module body cannot call its own
  # functions yet.
  load_config = fn raw, relative ->
    case Config.new(raw, file: relative) do
      {:ok, config} ->
        {config.name, {config, relative}}

      {:error, problems} ->
        raise ArgumentError, """
        invalid KG display config #{relative}:

          #{Enum.join(problems, "\n  ")}

        Fix the config, or run `mix linkouts.check` to see every problem across kgs/.
        """
    end
  end

  @configs for path <- Path.wildcard(Path.join(@kgs_dir, "*.exs")),
               not String.starts_with?(Path.basename(path), "_"),
               raw = path |> Code.eval_file() |> elem(0),
               do: load_config.(raw, Path.relative_to_cwd(path))

  for {_name, {_config, path}} <- @configs, do: @external_resource(path)

  @table Map.new(@configs)

  @type t :: Config.t()

  @doc "The KG names with a display config, sorted."
  @spec known() :: [String.t()]
  def known, do: @table |> Map.keys() |> Enum.sort()

  @doc "Every loaded config."
  @spec configs() :: [t()]
  def configs, do: for({config, _path} <- Map.values(@table), do: config)

  @doc """
  The config for a KG name, or nil.

  A KG that is stored but has no config still renders: the caller falls back to a generic view
  showing the raw fields. Missing display logic must never mean a blank page.
  """
  @spec get(String.t() | nil) :: t() | nil
  def get(nil), do: nil

  def get(name) do
    case Map.fetch(@table, name) do
      {:ok, {config, _path}} -> config
      :error -> nil
    end
  end

  @infores_prefix "infores:"

  @doc """
  The slug form of a KG name: the canonical name without its `infores:` registry prefix.

  The slug is what is stored on a document (`k`), what a pool document id is built from, and
  what a URL carries — `infores:drugapprovals-kp` becomes `/drugapprovals-kp/random`. A name
  with no prefix is already a slug, so this is safe to call on a URL segment a visitor typed.
  """
  @spec slug(String.t() | nil) :: String.t() | nil
  def slug(nil), do: nil
  def slug(name), do: String.replace_prefix(name, @infores_prefix, "")

  @doc """
  The canonical KG name for a slug.

  The config table is consulted first, so the answer is exactly the name a curator declared —
  including a KG that is not infores-registered, or one registered under a different scheme.
  A slug with no config expands to the `infores:` form, which is how every graph in this
  project is registered; a slug that already carries a scheme is returned unchanged rather
  than getting a second prefix stapled on.
  """
  @spec kg_from_slug(String.t() | nil) :: String.t() | nil
  def kg_from_slug(nil), do: nil

  def kg_from_slug(name) do
    wanted = slug(name)

    Enum.find_value(configs(), fn %Config{name: declared} ->
      if slug(declared) == wanted, do: declared
    end) || expand(wanted)
  end

  defp expand(slug) do
    if String.contains?(slug, ":"), do: slug, else: @infores_prefix <> slug
  end

  @doc """
  The KG name a version key belongs to.

  Keys are `<name>-<version>`, and names themselves contain hyphens, so the split is at the first
  segment that starts with a digit — the same rule `EdgeLinkouts.Codec` uses to order versions.
  """
  @spec name_of(String.t() | nil) :: String.t() | nil
  def name_of(nil), do: nil

  def name_of(key) do
    case String.split(key, "-") |> Enum.split_while(&(not starts_numeric?(&1))) do
      {[], _} -> nil
      {_name_parts, []} -> nil
      {name_parts, _version_parts} -> Enum.join(name_parts, "-")
    end
  end

  defp starts_numeric?(<<c, _::binary>>) when c in ?0..?9, do: true
  defp starts_numeric?(_), do: false

  @doc "The config for a version key, or nil."
  @spec for_key(String.t() | nil) :: t() | nil
  def for_key(key), do: key |> name_of() |> get()

  @doc "The build context for a resolved document at a version."
  @spec context(t(), map(), String.t()) :: Value.ctx()
  def context(%Config{} = config, doc, version) do
    %{
      doc: doc,
      version: version,
      slots: config.slots,
      aliases: Config.aliases_for(config, version)
    }
  end

  @doc "Renders the main sentence describing the relationship."
  @spec edge(t(), map(), String.t()) :: [Segment.t()]
  def edge(%Config{} = config, doc, version) do
    Value.render(config.edge, context(config, doc, version))
  end

  @doc """
  Renders the text relationship line, when the config declares one.

  The line carries subject, relation, object and every qualifier with the identifiers
  inline, which is why it replaces the three-box diagram for configs that declare it: a
  diagram card has exactly three slots and a real relationship has more.
  """
  @spec relationship(t(), map(), String.t()) :: [Segment.t()] | nil
  def relationship(%Config{relationship: nil}, _doc, _version), do: nil

  def relationship(%Config{} = config, doc, version) do
    Value.render(config.relationship, context(config, doc, version))
  end

  @doc "Renders the short label used for the page title and link previews."
  @spec title(t(), map(), String.t()) :: String.t()
  def title(%Config{title: nil} = config, doc, version) do
    # No title spec: fall back to the subject/object pair, which is what a reviewer needs to
    # recognise the edge in a tab strip or a Slack unfurl.
    ctx = context(config, doc, version)
    subject = Value.fetch(ctx, "subject_name") || Value.fetch(ctx, "subject") || "edge"
    object = Value.fetch(ctx, "object_name") || Value.fetch(ctx, "object") || "?"
    "#{subject} and #{object}"
  end

  def title(%Config{} = config, doc, version) do
    config.title |> Value.render(context(config, doc, version)) |> Segment.to_text()
  end

  @doc """
  Renders the evidence block as one paragraph of prose.

  Each config entry is a sentence; entries whose `:if` conditions fail, or whose template
  renders nothing, drop out, and what survives is joined with spaces into one segment list the
  page prints as a single paragraph. The legacy page ran the same facts as optional labelled
  lines; as prose, each sentence carries its own meaning, so no field-name label asks the
  reader to decode what a row is.
  """
  @spec evidence(t(), map(), String.t()) :: [Segment.t()]
  def evidence(%Config{} = config, doc, version) do
    ctx = context(config, doc, version)

    config.evidence
    |> Enum.filter(&Value.all?(Map.get(&1, :if, []), ctx))
    |> Enum.map(&Value.render(Map.get(&1, :value), ctx))
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([Segment.text(" ")])
    |> List.flatten()
  end

  @doc """
  The GitHub issue URL for correcting this edge, or nil without a configured repo.

  Carries the edge id and its permalink in the issue body so a correction is actionable without
  the reporter having to describe what they were looking at.
  """
  @spec feedback_url(t() | nil, String.t(), String.t() | nil) :: String.t() | nil
  def feedback_url(%Config{feedback_repo: repo}, id, permalink) when is_binary(repo) do
    body = permalink || id
    title = "feedback on relationship #{id}"

    repo
    |> String.trim_trailing("/")
    |> Kernel.<>("/issues/new?")
    |> Kernel.<>(URI.encode_query(%{"title" => title, "body" => body}))
  end

  def feedback_url(_config, _id, _permalink), do: nil

  @doc """
  Problems that make a config unusable. Empty means every loaded config renders.

  Several aliases for one field are legitimate — they form an ordered fallback chain, which is how
  clinical trials prefers `unii` over `subject` — so only an exact repeat (same field, same
  alternative, same version range) is reported. That is always a copy-paste mistake, and it
  silently does nothing, which is the worst kind of config bug.
  """
  @spec check_all() :: [String.t()]
  def check_all do
    Enum.flat_map(configs(), fn config ->
      config.aliases
      |> Enum.map(&{&1.field, &1.as, Map.get(&1, :versions)})
      |> Enum.frequencies()
      |> Enum.filter(fn {_rule, n} -> n > 1 end)
      |> Enum.map(fn {{field, as, versions}, n} ->
        scope = if versions, do: " for versions #{versions}", else: ""
        "#{config.file}: alias #{field} -> #{as}#{scope} is listed #{n} times"
      end)
    end)
  end

  @doc """
  Field names a config references that no slot defines, for cross-checking against real data.

  `{name}` falls back to a document field, so an undefined name is usually intentional — but it is
  also exactly what a typo looks like, and a typo renders as a silently shorter sentence. The
  check task compares these against the fields present in the committed contract fixtures, which
  turns "might be a typo" into "is not in any document this project has ever loaded".
  """
  @spec unresolved_names(t()) :: [String.t()]
  def unresolved_names(%Config{} = config), do: Config.undefined_slots(config)

  @doc "The loaded configs and their source files, for diagnostics."
  @spec loaded_files() :: [{String.t(), String.t()}]
  def loaded_files, do: for({name, {_config, path}} <- @configs, do: {name, path})
end
