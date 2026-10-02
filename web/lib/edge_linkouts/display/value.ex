defmodule EdgeLinkouts.Display.Value do
  @moduledoc """
  The declarative value grammar that KG configs are written in.

  A KG config never contains Elixir. It describes what to show, and this module interprets it
  against a resolved edge document. The grammar is deliberately small — five value forms and four
  conditions — because it has to cover six knowledge graphs whose Perl originals were each written
  by hand, and every form added here is a form a curator has to learn.

  Value forms:

      "literal text with {slot} interpolation"   a template string
      {:field, :name}                            one document field, as text
      {:link, :name_field, :curie_field}         a CURIE linkout (label + href)
      {:list, inner, separator}                  each element of a list field, joined
      {:pick, :field, %{value => spec, default: spec}}
                                                 choose a spec by field value
      {:url, "https://…{field}", label}          a link whose URL is built from fields
      {:if, conditions, then_spec, else_spec}    conditional inclusion

  Conditions: `{:present, :field}`, `{:eq, :field, value}`, `{:matches, :field, "regex"}`,
  `{:version, ">1.0.0"}`, and `{:all | :any, [...]}`.

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
          | {:pick, atom() | String.t(),
             %{optional(String.t()) => spec(), optional(:default) => spec()}}
          | {:url, String.t(), spec()}
          | {:if, [condition()], spec(), spec() | nil}
          | {:if, [condition()], spec()}

  @type condition ::
          {:present, atom() | String.t()}
          | {:eq, atom() | String.t(), term()}
          | {:matches, atom() | String.t(), String.t()}
          | {:version, String.t()}
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

  def render({:list, name, inner, separator}, ctx) do
    case fetch(ctx, name) do
      values when is_list(values) and values != [] ->
        values
        |> Enum.map(&render_element(&1, inner, ctx))
        |> Enum.reject(&(&1 == []))
        |> interleave(Segment.text(separator))
        |> Segment.join()

      _ ->
        []
    end
  end

  def render({:pick, name, branches}, ctx) do
    case fetch(ctx, name) do
      nil -> render(Map.get(branches, :default), ctx)
      value -> render(Map.get(branches, stringify(value), Map.get(branches, :default)), ctx)
    end
  end

  # A link whose URL is built from document fields: {:url, "https://…?query={subject_name}", label}.
  # Field values are percent-encoded, so a drug name with a space or an ampersand cannot break the
  # query or smuggle a parameter.
  def render({:url, template, label}, ctx) when is_binary(template) do
    url =
      Regex.replace(~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/, template, fn _full, name ->
        case fetch(ctx, name) do
          nil -> ""
          value -> URI.encode_www_form(stringify(value) || "")
        end
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
    {:list, name, inner, separator}, {:pick, name, branches} and {:if, conditions, then, else}.
    `mix linkouts.check` reports this at build time rather than on a page view.
    """
  end

  # A list element becomes the document for the inner spec: a map element (a KGX `sources` entry)
  # is read by field name, and a scalar element (a CURIE) is reachable as {self}. Keeping the
  # parent document out of scope is deliberate — inside a list, "resource_id" must mean this
  # element's, not one inherited from the edge.
  defp render_element(element, inner, ctx) do
    doc = if is_map(element), do: element, else: %{"__self__" => element}
    render(inner, %{ctx | doc: doc})
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
