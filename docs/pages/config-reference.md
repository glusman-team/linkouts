# Config reference

A config is a map with these keys:

| key | required | what it is |
|---|---|---|
| `name` | yes | the `<name>` of the version keys this config renders |
| `display_name` | yes | the human name, shown in the header and on the home page |
| `url` | | the knowledge source's own documentation |
| `description` | | prose about the KG, for the home page |
| `feedback_repo` | | GitHub repo whose issues take corrections for this KG |
| `aliases` | | alternative field spellings, see [Adding a KG](add-a-kg.md) |
| `slots` | | named value specs a template can reference as `{name}` |
| `title` | | short label for the page title; defaults to subject — object |
| `edge` | yes | the sentence describing the relationship |
| `evidence` | | rows for the evidence panel: `%{label: spec, value: spec, if: [conditions]}` |

## Value specs

Anywhere a value is expected you may write any of these forms.

### Template string

```elixir
"This relationship states that {subject} {relation} {object}."
```

Literal text with `{name}` references. A name is looked up as a **slot** first, then as a
**document field** (read through aliases). A name that resolves to nothing renders as nothing,
so `"{a}{b}"` with no `b` becomes the output of `{a}` alone.

### `{:field, name}`

One field from the document, as text. Lists are joined with `", "`.

### `{:link, label_field, curie_field}`

A linkout. The URL is built from the CURIE using `kgs/_prefixes.exs`. When the prefix has no
entry, or the CURIE is missing, the label is shown as plain text, because a dead link is worse
than no link. When the label is missing, the CURIE itself is shown.

### `{:list, name, inner, separator}`

Renders `inner` once per element of a list field. A scalar element is available as `{self}` or
`"self"`. A map element *becomes* the document for `inner`, so its keys are read by name:

```elixir
{:list, "publications", {:link, "self", "self"}, ", "}   # list of CURIEs
{:list, "sources", "{resource_id}", ", "}                 # list of KGX source maps
```

### `{:pick, name, branches}`

Chooses a spec by the field's value. `:default` is used for any value not listed and for a
missing field. `mix linkouts.check` requires a `:default`, because otherwise an unlisted value
renders nothing.

### `{:if, conditions, then}` and `{:if, conditions, then, else}`

Renders `then` when every condition holds, otherwise `else` (or nothing).

### `{:url, template, label}`

A link whose URL is built from fields. Each `{field}` in the template is percent-encoded, so a
value containing a space or an `&` cannot break the query string or add a parameter.

```elixir
{:url, "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query={subject_name}", "labels for {subject_name}"}
```

### `{:number, name, :sig2 | :int}`

`:sig2` gives two significant digits: `0.123456` becomes `0.12`. Very small and very large values
use scientific notation (`1.2e-9`). `:int` rounds to the nearest whole number. A value that is not
a number is shown as given.

Placeholders such as `"NA"` never reach a config. The CLI drops them at ingest (see
[Storage format](storage-format.md)), so a missing number is an absent field. Gate on it with
`{:present, field}`.

### `{:humanize, name}`

`biolink:correlated_with` becomes `correlated with`.

### `{:count, name}`

The length of a list field.

### `{:default, name, fallback}`

The field if present and non-empty, otherwise `fallback`, which is itself a spec.

## Conditions

| condition | true when |
|---|---|
| `{:present, name}` | the field exists and is not empty |
| `{:eq, name, value}` | the field equals `value`, compared as text |
| `{:matches, name, "regex"}` | the field matches the regex. Use this for predicate families such as `^biolink:contraindicated` |
| `{:lt \| :gt \| :lte \| :gte, name, number}` | the field is a number and compares true. A missing or non-number field is false, never an error |
| `{:count_gt, name, n}` | the list field has more than `n` elements |
| `{:version, ">1.0.0"}` | the version being displayed satisfies the requirement. Comparison is numeric, so `1.9.0 < 1.16.0` |
| `{:all, [...]}`, `{:any, [...]}` | combinators |

## Safety

Configs produce text and links, never HTML. Every value is escaped when the page renders, and
only `http` and `https` URLs become links. A `javascript:` URL renders as plain text. This holds
regardless of what the upstream KG contains.
