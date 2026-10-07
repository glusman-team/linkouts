defmodule EdgeLinkouts.Display.Value do
  @moduledoc """
  The declarative value grammar that KG configs are written in.

  A KG config never contains Elixir. It describes what to show, and this module interprets it
  against a resolved edge document. The grammar is kept small on purpose. Every form exists because a legacy KGinfo/*.pl file needed it,
  and each one added is another form a curator has to learn. The full list with examples is in
  `docs/pages/config-reference.md`.

  Value forms:

      "literal text with {slot} interpolation"   a template string
      {:field, :name}                            one document field, as text
      {:link, :name_field, :curie_field}         a CURIE linkout (label + href)
      {:list, inner, separator}                  each element of a list field, joined
      {:list, inner, separator, max, "and"}      capped, conjunct list ("A and B" / "A, B, and C")
      {:pick, :field, %{value => spec, default: spec}}
                                                 choose a spec by field value
      {:url, "https://…{field}", label}          a link whose URL is built from fields
      {:number, :field, :sig2 | :int}            a number formatted to 2 sig digits / integer
      {:humanize, :field}                        "biolink:correlated_with" -> "correlated with"
      {:count, :field}                           the length of a list
      {:default, :field, fallback}               fallback when the field is absent or empty
      {:or_query, name, original_name}           a Lucene OR group of every name a source
                                                 used for the concept: the preferred name
                                                 plus each pipe-delimited original, quoted
      {:supporting, key, prefix, suffix, rewordings, fallback}
                                                 text from a supporting_text "key: value"
                                                 entry, framed as "prefix + value + suffix";
                                                 rewordings swaps the value for a keyed
                                                 replacement (keys downcased)
      {:if, conditions, then_spec, else_spec}    conditional inclusion

  Conditions: `{:present, :field}`, `{:eq, :field, value}`, `{:matches, :field, "regex"}`,
  `{:lt | :gt | :lte | :gte, :field, number}`, `{:version, ">1.0.0"}`, and `{:all | :any, [...]}`.

  Missing values are the normal case in KGX, not an error: a field the release renamed, a node
  the join could not resolve. Every form renders to nothing when its input is absent, so a
  partially-populated edge produces a shorter sentence instead of a crash or the string "nil".
  """

  alias EdgeLinkouts.Display.{Segment, Version}

  @type spec ::
          String.t()
          | {:field, atom() | String.t()}
          | {:link, atom() | String.t(), atom() | String.t()}
          | {:list, atom() | String.t(), spec(), String.t()}
          | {:list, atom() | String.t(), spec(), String.t(), pos_integer()}
          | {:list, atom() | String.t(), spec(), String.t(), pos_integer(), String.t()}
          | {:pick, atom() | String.t(),
             %{optional(String.t()) => spec(), optional(:default) => spec()}}
          | {:url, String.t(), spec()}
          | {:number, atom() | String.t(), :sig2 | :int}
          | {:humanize, atom() | String.t()}
          | {:count, atom() | String.t()}
          | {:default, atom() | String.t(), spec()}
          | {:or_query, atom() | String.t(), atom() | String.t()}
          | {:supporting, String.t(), String.t(), String.t(),
             %{optional(String.t()) => String.t()}, spec()}
          | {:if, [condition()], spec(), spec() | nil}
          | {:if, [condition()], spec()}
          | {:fold, String.t(), spec()}
          | {:strong, spec()}

  @type condition ::
          {:present, atom() | String.t()}
          | {:eq, atom() | String.t(), term()}
          | {:matches, atom() | String.t(), String.t()}
          | {:version, String.t()}
          | {:lt | :gt | :lte | :gte, atom() | String.t(), number()}
          | {:count_gt, atom() | String.t(), non_neg_integer()}
          | {:all | :any, [condition()]}

  @type ctx :: %{
          doc: map(),
          version: String.t(),
          slots: %{required(String.t()) => spec()},
          aliases: %{required(String.t()) => [String.t()]}
        }

  @doc "Renders a spec to segments against a context."
  @spec render(spec(), ctx()) :: [Segment.t()]
  def render(nil, _ctx), do: []

  def render(spec, ctx) when is_binary(spec) do
    # Interpolate {slot} references. Text between slots is literal, so a template can be read as
    # the sentence it produces.
    spec
    |> String.split(~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/, include_captures: true, trim: true)
    |> Enum.flat_map(fn
      "{" <> _ = token ->
        token
        |> String.trim_leading("{")
        |> String.trim_trailing("}")
        |> lookup_slot(ctx)

      literal ->
        [Segment.text(literal)] |> Enum.reject(&is_nil/1)
    end)
    |> Segment.join()
  end

  def render({:field, name}, ctx) do
    case fetch(ctx, name) do
      nil -> []
      [] -> []
      value -> [Segment.text(stringify(value))]
    end
  end

  def render({:link, label_field, curie_field}, ctx) do
    label = fetch(ctx, label_field)
    curie = fetch(ctx, curie_field)

    case EdgeLinkouts.Display.Prefixes.linkout(stringify(label), stringify(curie)) do
      nil -> []
      segment -> [segment]
    end
  end

  def render({:list, name, inner, separator}, ctx),
    do: render_list(name, inner, separator, nil, nil, ctx)

  # The 5-tuple caps the inline run: the first `max` rendered items stay in the sentence, the
  # rest fold into one {:more} segment the page turns into a "show N more" disclosure. Twenty
  # SPL set ids printed inline turn a paragraph into a wall of UUIDs; three read, the rest are
  # one click away.
  def render({:list, name, inner, separator, max}, ctx) when is_integer(max) and max > 0,
    do: render_list(name, inner, separator, max, nil, ctx)

  # The 6-tuple adds a conjunction for prose lists: "A and B" for two items, "A, B, and C"
  # for more (Oxford comma). A fold suppresses it — the button would sit where the
  # conjunction belongs, and "A, B, [Show 2 more] and C" reads worse than plain commas.
  def render({:list, name, inner, separator, max, conjunction}, ctx)
      when is_integer(max) and max > 0 and is_binary(conjunction),
      do: render_list(name, inner, separator, max, conjunction, ctx)

  # {:strong, inner}: emphasis — rendered louder than the surrounding prose. Used for the
  # primary knowledge source in a source list, where bold carries the distinction a
  # "(primary)" parenthetical used to spell out. An empty inner means no emphasis.
  def render({:strong, inner}, ctx) do
    case render(inner, ctx) do
      [] -> []
      rendered -> [{:strong, rendered}]
    end
  end

  # {:fold, label, inner}: like a capped list's fold, but for a single fact the sentence is
  # better off without — a node's CURIE, which identifies but does not advance the claim. The
  # chip is named for what it holds ("curie"), not a count; expanding reveals the inner spec
  # in place. An inner render of nothing means no chip at all.
  def render({:fold, label, inner}, ctx) when is_binary(label) do
    case render(inner, ctx) do
      [] -> []
      rendered -> [{:fold, label, Segment.join([Segment.text(" ") | List.wrap(rendered)])}]
    end
  end

  def render({:pick, name, branches}, ctx) do
    case fetch(ctx, name) do
      nil -> render(Map.get(branches, :default), ctx)
      value -> render(Map.get(branches, stringify(value), Map.get(branches, :default)), ctx)
    end
  end

  # {:number, field, :sig2 | :int}: the legacy Perl used sprintf("%.2g", $p) and sprintf("%.0f", $n).
  # :sig2 renders two significant digits in scientific notation — a deliberate change from Perl's
  # %g, because "1.2e-9" is unambiguous at a glance where "0.0000000012" invites miscounting zeros.
  def render({:number, name, format}, ctx) do
    case fetch(ctx, name) do
      nil -> []
      value -> [Segment.text(format_number(value, format))]
    end
  end

  # {:humanize, field}: KGX predicates arrive as "biolink:correlated_with". The Perl stripped the
  # prefix and swapped underscores for spaces to get prose; same here.
  def render({:humanize, name}, ctx) do
    case fetch(ctx, name) do
      nil -> []
      value -> [Segment.text(humanize(stringify(value)))]
    end
  end

  # {:local, name}: the part of a CURIE after its prefix — "biolink:applied_to_treat" renders
  # as "applied_to_treat". The biolink model's docs site names every term's page by this local
  # id, so a sentence can link "its predicate is applied to treat" straight at the term's own
  # page; a {:url} template needs the bare id, and a template string cannot strip a prefix.
  def render({:local, name}, ctx) do
    case fetch(ctx, name) do
      nil ->
        []

      value ->
        case stringify(value) do
          nil -> []
          curie -> [Segment.text(curie |> String.split(":", parts: 2) |> List.last())]
        end
    end
  end

  # {:count, field}: the length of a list, for "3 clinical trials" phrasing.
  def render({:count, name}, ctx) do
    case fetch(ctx, name) do
      nil -> []
      value when is_list(value) -> [Segment.text(Integer.to_string(length(value)))]
      _value -> [Segment.text("1")]
    end
  end

  # {:default, field, fallback}: the Perl `//` and `||` idiom. A field the release dropped falls
  # back rather than blanking the sentence; the fallback is itself a spec, so it can be a literal,
  # another field, or a link.
  def render({:default, name, fallback}, ctx) do
    case fetch(ctx, name) do
      nil -> render(fallback, ctx)
      "" -> render(fallback, ctx)
      [] -> render(fallback, ctx)
      _value -> render({:field, name}, ctx)
    end
  end

  # DAKP logs how every assertion was read into the supporting_text list as "key: value"
  # entries; each qualifier carries its readable source phrase under original_{qualifier}
  # ("breast", "pediatric patients", "daily"). Pipe-separated alternates keep the first —
  # the canonical read, the same convention original_subject/original_object use. A rewording
  # map lets the curator repair values that read as fragments in a sentence ("adult" becomes
  # "adults", "7 days" becomes "for 7 days") without touching the stored data; keys are
  # downcased and matched case-insensitively. When the entry is absent the fallback renders,
  # so older blobs fall back to the labelled CURIE.
  def render({:supporting, key, prefix, suffix, rewordings, fallback}, ctx) do
    case supporting_value(ctx.doc, key) do
      nil ->
        render(fallback, ctx)

      value ->
        reworded = Map.get(rewordings, String.downcase(value), value)
        [Segment.text(prefix <> reworded <> suffix)]
    end
  end

  # DailyMed's query box takes Lucene boolean syntax, so a search can reach every name the
  # source used for a concept: the preferred name plus each pipe-delimited original (the
  # same convention original_subject/original_object use), each a quoted phrase, joined with
  # OR. Deduplication is case-insensitive because dumps routinely carry "Pain" and "PAIN";
  # the first spelling wins, which keeps the preferred name's casing when it survives.
  def render({:or_query, name, original_name}, ctx) do
    terms = query_terms([fetch(ctx, name), fetch(ctx, original_name)])

    terms
    |> Enum.map_join(" OR ", &~s("#{&1}"))
    |> Segment.text()
    |> List.wrap()
  end

  # A link whose URL is built from document fields: {:url, "https://…?query={subject_name}", label}.
  # Field values are percent-encoded, so a drug name with a space or an ampersand cannot break the
  # query or smuggle a parameter.
  def render({:url, template, label}, ctx) when is_binary(template) do
    # Slots resolve first, then fields, exactly like a string template: a URL may need a
    # transformed value (a CURIE's local id) just as much as a sentence does.
    url =
      Regex.replace(~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/, template, fn _full, name ->
        value =
          case Map.fetch(ctx.slots, name) do
            {:ok, spec} -> spec |> render(ctx) |> Segment.to_text()
            :error -> fetch(ctx, name) |> stringify()
          end

        URI.encode_www_form(value || "")
      end)

    text = label |> render(ctx) |> Segment.to_text()

    case Segment.link(url, text) do
      nil -> []
      segment -> [segment]
    end
  end

  def render({:if, conditions, then_spec, else_spec}, ctx) do
    if all?(conditions, ctx), do: render(then_spec, ctx), else: render(else_spec, ctx)
  end

  # The 3-tuple form is what configs naturally want: include this when true, otherwise nothing.
  def render({:if, conditions, then_spec}, ctx) do
    render({:if, conditions, then_spec, nil}, ctx)
  end

  def render(other, _ctx) do
    raise ArgumentError, """
    unsupported value spec: #{inspect(other)}

    Valid forms are a template string, {:field, name}, {:link, label_field, curie_field},
    {:list, name, inner, separator}, {:list, name, inner, separator, max}, {:list, name,
    inner, separator, max, conjunction}, {:fold, label, inner}, {:strong, inner}, {:pick,
    name, branches}, {:local, name} and {:if, conditions, then, else}.
    `mix linkouts.check` reports this at build time rather than on a page view.
    """
  end

  defp render_list(name, inner, separator, max, conjunction, ctx) do
    case fetch(ctx, name) do
      values when is_list(values) and values != [] ->
        rendered =
          values
          |> Enum.map(&render_element(&1, inner, ctx))
          |> Enum.reject(&(&1 == []))

        {shown, hidden} =
          if max && length(rendered) > max, do: Enum.split(rendered, max), else: {rendered, []}

        shown
        |> interleave_with(separator, conjunction, hidden)
        |> Kernel.++(more_segment(hidden, separator))
        |> Segment.join()

      _ ->
        []
    end
  end

  # A conjunction turns the comma run into prose: "KP and DailyMed" for two items, with the
  # Oxford comma from three up. Anything folded (or no conjunction) keeps plain separators.
  defp interleave_with(items, separator, conjunction, hidden)

  defp interleave_with(items, separator, conjunction, [])
       when is_binary(conjunction) and length(items) > 1 do
    {last, rest} = List.pop_at(items, -1)
    last_join = if length(rest) > 1, do: "#{separator}#{conjunction} ", else: " #{conjunction} "
    Enum.intersperse(rest, Segment.text(separator)) ++ [Segment.text(last_join), last]
  end

  defp interleave_with(items, separator, _conjunction, _hidden),
    do: interleave(items, Segment.text(separator))

  # The fold carries the leading separator so a flattened read (plain text, link extraction)
  # restores the exact sequence the open disclosure shows.
  defp more_segment([], _separator), do: []

  defp more_segment(hidden, separator) do
    [
      {:more,
       List.flatten([Segment.text(separator) | interleave(hidden, Segment.text(separator))])}
    ]
  end

  # A list element becomes the document for the inner spec: a map element (a KGX `sources` entry)
  # is read by field name, and a scalar element (a CURIE) is reachable as {self}. Keeping the
  # parent document out of scope is deliberate — inside a list, "resource_id" must mean this
  # element's, not one inherited from the edge.
  defp render_element(element, inner, ctx) do
    doc = if is_map(element), do: element, else: %{"__self__" => element}
    render(inner, %{ctx | doc: doc})
  end

  # Finds the value of a supporting_text "key: value" entry. The entry format is the
  # pipeline's log line, so the key is everything before the first colon and the value is
  # everything after it, trimmed. An empty value counts as absent: the fallback must win,
  # or a sentence would carry a dangling frame like ", in the ".
  defp supporting_value(doc, key) do
    doc
    |> Map.get("supporting_text")
    |> supporting_entries()
    |> Enum.find_value(fn entry ->
      case String.split(entry, ":", parts: 2) do
        [entry_key, value] when entry_key == key ->
          value
          |> String.split("|")
          |> List.first()
          |> String.trim()
          |> case do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end
    end)
  end

  defp supporting_entries(entries) when is_binary(entries), do: [entries]
  defp supporting_entries(entries) when is_list(entries), do: Enum.filter(entries, &is_binary/1)
  defp supporting_entries(_other), do: []

  defp query_terms(fields) do
    fields
    |> Enum.flat_map(fn
      value when is_binary(value) -> [value]
      value when is_list(value) -> Enum.filter(value, &is_binary/1)
      _ -> []
    end)
    |> Enum.flat_map(&String.split(&1, "|"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  @doc "Evaluates every condition; an empty list is true."
  @spec all?([condition()], ctx()) :: boolean()
  def all?(conditions, ctx), do: Enum.all?(conditions, &condition?(&1, ctx))

  @doc "Evaluates one condition."
  @spec condition?(condition(), ctx()) :: boolean()
  def condition?({:present, name}, ctx) do
    case fetch(ctx, name) do
      nil -> false
      "" -> false
      [] -> false
      _ -> true
    end
  end

  def condition?({:eq, name, expected}, ctx) do
    case fetch(ctx, name) do
      nil -> false
      value -> stringify(value) == stringify(expected)
    end
  end

  def condition?({:version, requirement}, ctx) do
    Version.satisfies?(ctx.version, requirement)
  end

  # A regex condition, for predicates that arrive as a family rather than one value: the drug
  # approvals KG has several contraindication predicates and the legacy code matched them all with
  # /^biolink:contraindicated/. Compiled at call time, which is cheap relative to a Cosmos read.
  def condition?({:matches, name, pattern}, ctx) do
    case fetch(ctx, name) do
      nil -> false
      value -> Regex.match?(Regex.compile!(pattern), stringify(value))
    end
  end

  # Numeric comparisons, for "positively/negatively associated" driven by a coefficient's sign.
  # A missing or non-numeric value is false rather than an error: half the releases in the wild
  # omit these fields, and a blank sentence beats a crash.
  for {tag, op} <- [lt: :<, gt: :>, lte: :<=, gte: :>=] do
    def condition?({unquote(tag), name, bound}, ctx) when is_number(bound) do
      case fetch(ctx, name) do
        value when is_number(value) -> Kernel.unquote(op)(value, bound)
        _ -> false
      end
    end

    def condition?({unquote(tag), _name, bound}, _ctx) do
      raise ArgumentError,
            "{:#{unquote(tag)}, field, bound} needs a numeric bound, got #{inspect(bound)}"
    end
  end

  # Length of a list field, for pluralization. Counting is not expressible with the numeric
  # comparisons, which read a number out of the document rather than measuring a list.
  def condition?({:count_gt, name, bound}, ctx) when is_integer(bound) do
    case fetch(ctx, name) do
      value when is_list(value) -> length(value) > bound
      nil -> false
      _ -> 1 > bound
    end
  end

  def condition?({:count_gt, _, bound}, _ctx) do
    raise ArgumentError, "{:count_gt, field, integer} expected, got bound #{inspect(bound)}"
  end

  def condition?({:all, conditions}, ctx), do: all?(conditions, ctx)
  def condition?({:any, conditions}, ctx), do: Enum.any?(conditions, &condition?(&1, ctx))

  def condition?(other, _ctx) do
    raise ArgumentError,
          "unsupported condition: #{inspect(other)} (expected :present, :eq, :version, :all or :any)"
  end

  @doc """
  Reads a field, trying the canonical name and then any aliases configured for this version.

  This indirection is why real DAKP releases work: `FDA_regulatory_approvals` became
  `regulatory_approvals`, and not on a clean version boundary — the same version appears in two
  dumps with different spellings. Taking the first candidate that is present means one config
  renders both, and a document carrying the canonical spelling is never shadowed by a stale alias.
  """
  @spec fetch(ctx(), atom() | String.t()) :: term() | nil
  def fetch(ctx, name) do
    key = to_string(name)

    # :self is how {:list, ...} passes a scalar element to its inner spec.
    if key == "self" do
      Map.get(ctx.doc, "__self__")
    else
      ctx
      |> Map.get(:aliases, %{})
      |> Map.get(key, [key])
      |> Enum.find_value(fn candidate ->
        case Map.fetch(ctx.doc, candidate) do
          {:ok, value} -> value
          :error -> nil
        end
      end)
    end
  end

  @doc """
  Resolves a `{name}` reference: a defined slot if there is one, otherwise a document field.

  Slot-first means a config can override how any field renders by defining a slot with that name,
  and field fallback means `{subject_name}` works without ceremony. The fallback reads through
  version aliases, so `{regulatory_approvals}` resolves in both 1.11.2 and 1.16.0 documents.
  """
  @spec lookup_slot(String.t(), ctx()) :: [Segment.t()]
  def lookup_slot(name, ctx) do
    case Map.fetch(ctx.slots, name) do
      {:ok, spec} -> render(spec, ctx)
      :error -> render({:field, name}, ctx)
    end
  end

  defp format_number(value, :int) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value, :int) when is_float(value), do: Integer.to_string(round(value))
  defp format_number(value, :int), do: stringify(value) || ""

  # Two significant digits. Small and large magnitudes use scientific notation with an unpadded
  # exponent ("1.2e-9", not Erlang's "1.2e-09"), which is the form a reader expects for p-values;
  # ordinary magnitudes print plainly so a coefficient of 0.42 does not become "4.2e-1".
  defp format_number(value, :sig2) when is_float(value) do
    magnitude = abs(value)

    if magnitude != 0.0 and (magnitude < 1.0e-3 or magnitude >= 1.0e4) do
      # Erlang writes "1.2e-09"; strip the exponent's padding and any explicit "+".
      Regex.replace(~r/e([+-])0*(\d+)$/, :erlang.float_to_binary(value, scientific: 1), fn
        _, "+", digits -> "e" <> digits
        _, "-", digits -> "e-" <> digits
      end)
    else
      value |> Float.round(significant_decimals(magnitude)) |> trim_trailing_zero()
    end
  end

  defp format_number(value, :sig2) when is_integer(value), do: Integer.to_string(value)
  # A source that spells a missing number "NA" must not become "0" or crash the render.
  defp format_number(value, :sig2), do: stringify(value) || ""

  defp format_number(_value, other) do
    raise ArgumentError,
          "unsupported {:number, field, #{inspect(other)}} format; expected :sig2 or :int"
  end

  # Decimals needed for two significant digits at this magnitude: 0.123 -> 2, 0.0123 -> 3, 12.3 -> 0.
  defp significant_decimals(magnitude) when magnitude == 0.0, do: 0

  defp significant_decimals(magnitude) do
    max(0, 1 - floor(:math.log10(magnitude)))
  end

  defp trim_trailing_zero(rounded) do
    case Float.ratio(rounded) do
      {_, 1} -> rounded |> trunc() |> Integer.to_string()
      _ -> :erlang.float_to_binary(rounded, [:short])
    end
  end

  defp humanize(value) do
    value
    |> String.replace(~r/^biolink:/i, "")
    |> String.replace("_", " ")
  end

  defp interleave([single], _sep), do: [single]
  defp interleave([], _sep), do: []
  defp interleave([head | rest], sep), do: [head, sep | interleave(rest, sep)]

  @doc "The printable form of a document value."
  @spec stringify(term()) :: String.t() | nil
  def stringify(nil), do: nil
  def stringify(value) when is_binary(value), do: value
  def stringify(value) when is_integer(value), do: Integer.to_string(value)
  def stringify(value) when is_float(value), do: trim_float(value)
  def stringify(value) when is_boolean(value), do: Atom.to_string(value)
  def stringify([]), do: nil

  def stringify(value) when is_list(value),
    do: value |> Enum.map(&stringify/1) |> Enum.reject(&is_nil/1) |> Enum.join(", ")

  def stringify(value) when is_map(value), do: value |> JSON.encode!()

  # 12.0 is a count of something, not a measurement; showing "12" matches what the legacy page
  # printed and avoids implying precision the source never had.
  defp trim_float(value) do
    case Float.ratio(value) do
      {_, 1} -> Integer.to_string(trunc(value))
      _ -> :erlang.float_to_binary(value, [:short])
    end
  end
end
