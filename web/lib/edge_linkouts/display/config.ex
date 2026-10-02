defmodule EdgeLinkouts.Display.Config do
  @moduledoc """
  The shape of a KG display config, and its validation.

  Configs live in `kgs/*.exs` as plain Elixir terms and are loaded at compile time. They contain
  no code — only data in the grammar `EdgeLinkouts.Display.Value` interprets — so a curator can
  add a knowledge graph without touching the application, and `mix linkouts.check` can prove a
  config is well-formed without rendering a page.

  Validation is recursive over the value grammar, not just over the top-level keys. That matters
  because the failure mode of a typo'd spec is otherwise a blank sentence in production: a
  `{:pick, ...}` naming a field the release renamed renders nothing, and nothing looks like
  missing data.
  """

  alias EdgeLinkouts.Display.Version

  @schema NimbleOptions.new!(
            name: [
              type: :string,
              required: true,
              doc:
                "The KGX name, as in `<name>-<version>` keys. Must match the key prefix the CLI loads."
            ],
            display_name: [
              type: :string,
              required: true,
              doc: "Human name shown in the header and on the home page."
            ],
            url: [type: :string, doc: "Link to the knowledge source's own documentation."],
            description: [
              type: :string,
              doc: "Prose about the KP, shown on the home page and in the header."
            ],
            feedback_repo: [
              type: :string,
              doc: "GitHub repo whose issue tracker takes corrections for this KG."
            ],
            aliases: [
              type: {:list, :map},
              default: [],
              doc: """
              Alternative spellings for a field, tried in order after the canonical name:
              `%{field: "regulatory_approvals", as: "FDA_regulatory_approvals"}`. Add
              `versions: "<1.16.0"` to restrict one to a version range.

              Needed because real DAKP releases rename fields — and not cleanly: the same version
              can appear in two dumps with different spellings. So these are fallbacks, not
              replacements: the canonical key wins when present, and a config that names only the
              current spelling still renders older documents.
              """
            ],
            slots: [
              type: {:map, :string, :any},
              default: %{},
              doc: "Named value specs a template can reference as `{name}`."
            ],
            title: [type: :any, doc: "Short label for the page title and link previews."],
            edge: [type: :any, required: true, doc: "The sentence describing this relationship."],
            evidence: [
              type: {:list, :map},
              default: [],
              doc:
                "Evidence panel sections, each `%{label: spec, value: spec}` with optional `:if` conditions."
            ]
          )

  defstruct [
    :name,
    :display_name,
    :url,
    :description,
    :feedback_repo,
    :aliases,
    :slots,
    :title,
    :edge,
    :evidence,
    :file
  ]

  @type t :: %__MODULE__{}

  @doc "The NimbleOptions schema, for docs and for `mix linkouts.check`."
  def schema, do: @schema

  @doc """
  Validates a raw config map and returns a struct.

  Returns `{:error, problems}` where `problems` is a list of human-readable strings, so a bad
  config reports every mistake at once instead of one per rebuild.
  """
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def new(raw, opts \\ []) when is_map(raw) do
    file = Keyword.get(opts, :file, "<unknown>")

    with {:ok, validated} <- validate_schema(raw),
         :ok <- validate_aliases(validated[:aliases], file),
         :ok <- validate_slots(validated[:slots], file),
         :ok <- validate_spec(validated[:edge], "edge", file),
         :ok <- validate_optional_spec(validated[:title], "title", file),
         :ok <- validate_evidence(validated[:evidence], file) do
      {:ok, struct(__MODULE__, Map.put(validated, :file, file))}
    else
      {:error, %NimbleOptions.ValidationError{} = err} ->
        {:error, ["#{file}: #{Exception.message(err)}"]}

      {:error, problems} ->
        {:error, problems}
    end
  end

  defp validate_schema(raw) do
    case NimbleOptions.validate(raw |> Map.new(fn {k, v} -> {to_key(k), v} end), @schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, err} -> {:error, err}
    end
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key(k) when is_binary(k), do: String.to_atom(k)

  # --- grammar validation ---------------------------------------------------------------

  defp validate_slots(slots, file) do
    problems =
      for {name, spec} <- slots,
          problem <- spec_problems(spec, "slots.#{name}"),
          do: "#{file}: #{problem}"

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp validate_spec(spec, where, file) do
    case spec_problems(spec, where) do
      [] -> :ok
      problems -> {:error, Enum.map(problems, &"#{file}: #{&1}")}
    end
  end

  defp validate_optional_spec(nil, _where, _file), do: :ok
  defp validate_optional_spec(spec, where, file), do: validate_spec(spec, where, file)

  defp validate_evidence(sections, file) do
    problems =
      for {%{} = section, index} <- Enum.with_index(sections),
          problem <- section_problems(section, "evidence[#{index}]"),
          do: "#{file}: #{problem}"

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp section_problems(section, where) do
    required =
      for key <- [:value],
          not Map.has_key?(section, key),
          do: "#{where}: missing required key #{inspect(key)}"

    value = spec_problems(Map.get(section, :value), "#{where}.value")

    label =
      spec_problems(Map.get(section, :label), "#{where}.label")
      |> Enum.reject(&(&1 =~ "nil spec"))

    conditions = condition_problems(Map.get(section, :if, []), "#{where}.if")
    required ++ value ++ label ++ conditions
  end

  @doc false
  # Every problem in a spec, depth-first. Slot references cannot be checked here (a slot may be
  # defined in the same config), so Display.check_slots/1 does that pass once the whole config is
  # loaded.
  def spec_problems(nil, _where), do: ["nil spec"]
  def spec_problems(spec, _where) when is_binary(spec), do: []

  def spec_problems({:field, name}, _where) when is_binary(name) or is_atom(name), do: []

  def spec_problems({:field, other}, where),
    do: ["#{where}: {:field, _} needs a name, got #{inspect(other)}"]

  def spec_problems({:link, label, curie}, _where)
      when (is_binary(label) or is_atom(label)) and (is_binary(curie) or is_atom(curie)), do: []

  def spec_problems({:link, _, _} = other, where),
    do: ["#{where}: {:link, label_field, curie_field} expected, got #{inspect(other)}"]

  def spec_problems({:list, name, inner, separator}, where) do
    cond do
      not (is_binary(name) or is_atom(name)) -> ["#{where}: {:list, ...} needs a field name"]
      not is_binary(separator) -> ["#{where}: {:list, ...} separator must be a string"]
      true -> spec_problems(inner, "#{where}.inner")
    end
  end

  def spec_problems({:list, other}, where),
    do: ["#{where}: {:list, name, inner, separator} expected, got #{inspect(other)}"]

  def spec_problems({:pick, name, branches}, where) when is_map(branches) do
    name_problems =
      if is_binary(name) or is_atom(name),
        do: [],
        else: ["#{where}: {:pick, ...} needs a field name"]

    branch_problems =
      for {key, spec} <- branches,
          problem <- spec_problems(spec, "#{where}.#{inspect(key)}"),
          do: problem

    has_default =
      if Map.has_key?(branches, :default),
        do: [],
        else: [
          "#{where}: {:pick, #{name}, ...} has no :default branch, so an unlisted value renders nothing"
        ]

    name_problems ++ branch_problems ++ has_default
  end

  def spec_problems({:pick, _, _} = other, where),
    do: ["#{where}: {:pick, name, branches_map} expected, got #{inspect(other)}"]

  def spec_problems({:number, name, format}, _where)
      when (is_binary(name) or is_atom(name)) and format in [:sig2, :int], do: []

  def spec_problems({:number, _, _} = other, where),
    do: ["#{where}: {:number, field, :sig2 | :int} expected, got #{inspect(other)}"]

  def spec_problems({tag, name}, _where)
      when tag in [:humanize, :count] and (is_binary(name) or is_atom(name)), do: []

  def spec_problems({tag, _} = other, where) when tag in [:humanize, :count],
    do: ["#{where}: {#{inspect(tag)}, field} expected, got #{inspect(other)}"]

  def spec_problems({:default, name, fallback}, where) when is_binary(name) or is_atom(name) do
    spec_problems(fallback, "#{where}.fallback")
  end

  def spec_problems({:default, _, _} = other, where),
    do: ["#{where}: {:default, field, fallback} expected, got #{inspect(other)}"]

  def spec_problems({:url, template, label}, where) when is_binary(template) do
    spec_problems(label, "#{where}.label")
  end

  def spec_problems({:url, _, _} = other, where),
    do: ["#{where}: {:url, \"template\", label} expected, got #{inspect(other)}"]

  def spec_problems({:if, conditions, then_spec}, where) do
    spec_problems({:if, conditions, then_spec, nil}, where)
  end

  def spec_problems({:if, conditions, then_spec, else_spec}, where) do
    condition_problems(conditions, "#{where}.if") ++
      spec_problems(then_spec, "#{where}.then") ++
      case else_spec do
        nil -> []
        spec -> spec_problems(spec, "#{where}.else")
      end
  end

  def spec_problems(other, where), do: ["#{where}: unsupported spec #{inspect(other)}"]

  defp condition_problems(conditions, where) when is_list(conditions) do
    Enum.flat_map(conditions, &condition_problem(&1, where))
  end

  defp condition_problems(other, where),
    do: ["#{where}: conditions must be a list, got #{inspect(other)}"]

  defp condition_problem({:present, name}, _where) when is_binary(name) or is_atom(name), do: []

  defp condition_problem({:present, other}, where),
    do: ["#{where}: {:present, name} expected, got #{inspect(other)}"]

  defp condition_problem({:eq, name, _value}, _where) when is_binary(name) or is_atom(name),
    do: []

  defp condition_problem({:eq, _, _} = other, where),
    do: ["#{where}: {:eq, name, value} expected, got #{inspect(other)}"]

  defp condition_problem({:matches, name, pattern}, _where)
       when (is_binary(name) or is_atom(name)) and is_binary(pattern), do: []

  defp condition_problem({:matches, _, _} = other, where),
    do: ["#{where}: {:matches, name, \"regex\"} expected, got #{inspect(other)}"]

  # Parsed eagerly so a bad requirement fails `mix linkouts.check` instead of raising on the first
  # page view that evaluates it. Implicit try: the rescue belongs to this function, not a block.
  defp condition_problem({:version, requirement}, where) when is_binary(requirement) do
    Version.satisfies?("0.0.1", requirement)
    []
  rescue
    ArgumentError -> ["#{where}: bad version requirement #{inspect(requirement)}"]
  end

  defp condition_problem({:version, other}, where),
    do: ["#{where}: {:version, \"<op><version>\"} expected, got #{inspect(other)}"]

  # Numeric comparisons, for direction words driven by a coefficient's sign.
  defp condition_problem({tag, name, bound}, _where)
       when tag in [:lt, :gt, :lte, :gte] and (is_binary(name) or is_atom(name)) and
              is_number(bound),
       do: []

  defp condition_problem({tag, _, _} = other, where) when tag in [:lt, :gt, :lte, :gte],
    do: ["#{where}: {#{inspect(tag)}, field, number} expected, got #{inspect(other)}"]

  # Length of a list field, used for pluralization ("a clinical trial" vs "3 clinical trials").
  defp condition_problem({:count_gt, name, bound}, _where)
       when (is_binary(name) or is_atom(name)) and is_integer(bound),
       do: []

  defp condition_problem({:count_gt, _, _} = other, where),
    do: ["#{where}: {:count_gt, field, integer} expected, got #{inspect(other)}"]

  defp condition_problem({op, conditions}, where)
       when op in [:all, :any] and is_list(conditions) do
    Enum.flat_map(conditions, &condition_problem(&1, "#{where}.#{op}"))
  end

  defp condition_problem(other, where), do: ["#{where}: unsupported condition #{inspect(other)}"]

  defp validate_aliases(aliases, file) do
    problems =
      Enum.flat_map(aliases, fn
        %{field: field, as: as} = rule when is_binary(field) and is_binary(as) ->
          case Map.get(rule, :versions) do
            nil ->
              []

            versions when is_binary(versions) ->
              requirement_problems(file, field, versions)

            other ->
              [
                "#{file}: alias #{field} :versions must be a string requirement, got #{inspect(other)}"
              ]
          end

        %{field: field} ->
          ["#{file}: alias #{inspect(field)} needs an :as key naming the alternative spelling"]

        other ->
          ["#{file}: alias must be a map with :field and :as, got #{inspect(other)}"]
      end)

    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc """
  The candidate keys for each canonical field name at a specific version.

  Returns `%{canonical => [canonical, alias, ...]}` in lookup order, with aliases whose version
  requirement the key does not satisfy dropped. `Value.fetch/2` walks the list and takes the first
  key present in the document, so a doc that uses the canonical spelling is never shadowed by an
  older one, and a doc that only has the old spelling still renders.

  Version-scoped and unscoped aliases for one field may coexist; the scoped ones come first
  because they carry more information about which spelling that release meant.
  """
  @spec aliases_for(t(), String.t()) :: %{String.t() => [String.t()]}
  def aliases_for(%__MODULE__{aliases: aliases}, version_key) do
    matching =
      for %{field: field, as: as} = alias_ <- aliases,
          matches_version?(Map.get(alias_, :versions), version_key) do
        {field, as, Map.get(alias_, :versions) != nil}
      end

    scoped = for {field, as, true} <- matching, do: {field, as}
    unscoped = for {field, as, false} <- matching, do: {field, as}

    Enum.reduce(scoped ++ unscoped, %{}, fn {field, as}, acc ->
      Map.update(acc, field, [field, as], fn candidates ->
        if as in candidates, do: candidates, else: candidates ++ [as]
      end)
    end)
  end

  # Parsed eagerly so a bad requirement fails `mix linkouts.check` instead of raising on the
  # first page view that evaluates it.
  defp requirement_problems(file, field, requirement) do
    Version.satisfies?("0.0.1", requirement)
    []
  rescue
    ArgumentError ->
      ["#{file}: alias #{field} has a bad version requirement #{inspect(requirement)}"]
  end

  defp matches_version?(nil, _version_key), do: true

  defp matches_version?(requirement, version_key),
    do: Version.satisfies?(version_key, requirement)

  @doc """
  Every `{name}` a config references, from templates and slot definitions alike.

  `{name}` resolves to a defined slot or falls back to a document field, so this list is not by
  itself a set of mistakes — `mix linkouts.check` cross-checks it against the field names that
  actually appear in the committed contract fixtures to tell a typo from a legitimate field.
  """
  @spec referenced_names(t()) :: [String.t()]
  def referenced_names(%__MODULE__{} = config) do
    ([config.edge, config.title] ++
       Enum.flat_map(config.evidence, &[Map.get(&1, :label), Map.get(&1, :value)]) ++
       Map.values(config.slots))
    |> Enum.flat_map(&collect_spec_slots/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Slot names a template references but the config does not define.

  Not an error on its own, because `{name}` legitimately falls back to a document field. Kept
  public so the check task and tests can reason about it.
  """
  @spec undefined_slots(t()) :: [String.t()]
  def undefined_slots(%__MODULE__{} = config) do
    defined = Map.keys(config.slots)
    referenced = referenced_slots(config.edge) ++ referenced_slots(config.title)

    referenced =
      referenced ++
        Enum.flat_map(config.evidence, fn section ->
          referenced_slots(Map.get(section, :label)) ++ referenced_slots(Map.get(section, :value))
        end) ++
        Enum.flat_map(Map.values(config.slots), &collect_spec_slots/1)

    # uniq/1 before --: list subtraction is multiset subtraction, so a slot referenced by two
    # branches would survive one removal and be reported as missing.
    (Enum.uniq(referenced) -- defined) |> Enum.sort()
  end

  defp referenced_slots(nil), do: []
  defp referenced_slots(spec) when is_binary(spec), do: collect_spec_slots(spec)
  defp referenced_slots(spec), do: collect_spec_slots(spec)

  defp collect_spec_slots(nil), do: []

  defp collect_spec_slots(spec) when is_binary(spec) do
    Regex.scan(~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/, spec, capture: :all_but_first) |> List.flatten()
  end

  defp collect_spec_slots({:list, _name, inner, _sep}), do: collect_spec_slots(inner)

  defp collect_spec_slots({:pick, _name, branches}) when is_map(branches) do
    Enum.flat_map(Map.values(branches), &collect_spec_slots/1)
  end

  defp collect_spec_slots({:if, _conditions, then_spec, else_spec}) do
    collect_spec_slots(then_spec) ++ collect_spec_slots(else_spec)
  end

  defp collect_spec_slots({:default, _name, fallback}), do: collect_spec_slots(fallback)
  defp collect_spec_slots({:url, _template, label}), do: collect_spec_slots(label)

  defp collect_spec_slots({:if, _conditions, then_spec}) do
    collect_spec_slots(then_spec)
  end

  defp collect_spec_slots(_other), do: []
end
