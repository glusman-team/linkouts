# Config reference

A config is a map with these keys:

| key | required | what it is |
|---|---|---|
| `name` | yes | the `<name>` of the version keys this config renders |
| `extends` | | the base config this one builds on; only `"default"` is valid. See [The default config](the-default-config.md) |
| `display_name` | | the human name, shown in the edge page header; when omitted the header names the graph from the stored version key |
| `url` | | the knowledge source's own documentation |
| `description` | | prose about the KG, shown in the edge page's about section |
| `feedback_repo` | | GitHub repo whose issues take corrections for this KG |
| `aliases` | | alternative field spellings, see [Adding a KG](add-a-kg.md) |
| `slots` | | named value specs a template can reference as `{name}` |
| `title` | | short label for the page title; defaults to "subject and object" |
| `edge` | yes | the sentence describing the relationship |
| `relationship` | | the text relationship line, identifiers and exact biolink terms inline; replaces the diagram when present |
| `latest_version` | | release number this config was written against ("1.16.0"); the page tags it "latest" |
| `evidence` | | sentences for the evidence paragraph: `%{value: spec, if: [conditions]}`. Every sentence that passes its conditions renders into one prose paragraph on the edge page |

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

A link whose URL is built from the template. Each `{name}` resolves as a slot first, then a
field, and is percent-encoded, so a value containing a space or an `&` cannot break the query
string or add a parameter.

```elixir
{:url, "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query={subject_name}", "labels for {subject_name}"}
```

### `{:local, name}`

The part of a CURIE after its prefix: `biolink:applied_to_treat` renders as `applied_to_treat`.
The biolink model's docs name every term's page by this local id, so a slot pair can turn a
stored predicate into a link at the term's own documentation page.

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

### `{:fold, label, inner}`

`inner` collapsed into an expandable chip labelled `label` ("curie 1024"). A collapsed chip
identifies without interrupting the sentence; expanding reveals `inner` in place. Nothing
renders when `inner` renders nothing.

### `{:strong, inner}`

`inner` in bold.

### `{:supporting, key, prefix, suffix, rewordings, fallback}`

Text from a `supporting_text` entry. KGs log how an assertion was read as `"key: value"`
strings (`"original_frequency_qualifier: daily dosage"`), so this form fetches `key`'s value
and frames it as `prefix` + value + `suffix`. `rewordings` is a map of replacements applied
to the value (keys downcased), for repairing fragments that read badly in prose:

```elixir
{:supporting, "original_frequency_qualifier", ", dosed ", "",
 %{"dosage" => "at the labeled dosage"}, ", frequency {frequency_qualifier_link}"}
```

When the entry is absent the `fallback` renders, so a document from before the convention
falls back to a labelled CURIE instead of printing an empty frame.

### `{:or_query, name, original_name}`

A Lucene OR group of every name a source used for a concept: the preferred field plus each
pipe-delimited original, each a quoted phrase, deduplicated case-insensitively (first
spelling wins). Built for `{:url, ...}` search templates:

```elixir
"subject_query" => {:or_query, "subject_name", "original_subject"},
{:url, "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query={subject_query}", "labels for {subject_name}"}
```

renders the query `"gamma-Hydroxybutyric acid" OR "sodium oxybate"` while the link text stays
readable.

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
