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

  @doc "Renders the short label used for the page title and link previews."
  @spec title(t(), map(), String.t()) :: String.t()
  def title(%Config{title: nil} = config, doc, version) do
    # No title spec: fall back to the subject/object pair, which is what a reviewer needs to
    # recognise the edge in a tab strip or a Slack unfurl.
    ctx = context(config, doc, version)
    subject = Value.fetch(ctx, "subject_name") || Value.fetch(ctx, "subject") || "edge"
    object = Value.fetch(ctx, "object_name") || Value.fetch(ctx, "object") || "?"
    "#{subject} — #{object}"
  end

  def title(%Config{} = config, doc, version) do
    config.title |> Value.render(context(config, doc, version)) |> Segment.to_text()
  end

  @doc """
  Renders the evidence panel.

  Returns `%{label: [Segment.t()], value: [Segment.t()]}` per section, skipping any whose `:if`
  conditions fail or whose value renders empty — an evidence row with no data is worse than no
  row, because it implies the field exists and is blank.
  """
  @spec evidence(t(), map(), String.t()) :: [%{label: [Segment.t()], value: [Segment.t()]}]
  def evidence(%Config{} = config, doc, version) do
    ctx = context(config, doc, version)

    for section <- config.evidence,
        Value.all?(Map.get(section, :if, []), ctx),
        value = Value.render(Map.get(section, :value), ctx),
        value != [] do
      %{label: Value.render(Map.get(section, :label), ctx), value: value}
    end
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

  A duplicate alias is fatal because which rename wins would depend on map order.
  """
  @spec check_all() :: [String.t()]
  def check_all do
    Enum.flat_map(configs(), fn config ->
      case Enum.frequencies_by(config.aliases, & &1.field)
           |> Enum.filter(fn {_, n} -> n > 1 end) do
        [] -> []
        fields -> ["#{config.file}: duplicate alias for #{inspect(fields)}"]
      end
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
