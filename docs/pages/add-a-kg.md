# Adding a KG

A KG gets readable pages once it has a display config in `kgs/`. A config is an Elixir file
holding plain data. It has no functions, so you never write a template engine or HTML.

## 1. Generate a starter from real data

```sh
cli/bin/linkouts rig path/to/edges.ndjson --exs > kgs/my_kg.exs
```

`rig` reads the edges and writes a config that **compiles as-is**. It lists the predicates it saw
and has one evidence sentence for every field the KG asserts, phrased "Field name: …" so the
reader never meets a storage key. Each sentence is gated on the field being present, so an edge
that lacks a field never shows a sentence with a hole in it. Fields that are lists of CURIEs
are already linked.

Before writing the config, run `rig` without `--exs` for a report of what is in the file: which
predicates appear, which fields each one carries, and how often.

## 2. Make it yours

Open the file and change three things.

**The name.** This must equal the `<name>` part of the key you load with, in its canonical
infores form. For a load of `infores:my-kp-1.0.0`, use `name: "infores:my-kp"`. The name without
the prefix is its **slug** (`my-kp`): that is what the stored documents carry, what the root page
shows a row for, and what a URL uses (`/my-kp/random`). A page whose KG name has no config falls
back to a generic view, and its slug still works in a URL.

**The sentence.** The starter's `edge:` reads "X predicate Y". Most KGs want the wording to
depend on the predicate:

```elixir
slots: %{
  "subject" => {:link, "subject_name", "subject"},
  "object" => {:link, "object_name", "object"},
  "relation" =>
    {:pick, "predicate",
     %{
       "biolink:treats" => "has been approved for treating",
       :default => "has been used for treating"
     }}
},

edge: "This relationship states that {subject} {relation} {object}."
```

**The evidence sentences.** Delete the sentences a reviewer does not need and rewrite the rest
in the KG's voice — the legacy KGinfo pages read as prose, and so should these.

## 3. Check it

```sh
cd web && mix linkouts.check
```

This validates every config in `kgs/`. It reports every problem at once, with the file and the
location inside it, so you are not fixing one error per rebuild. It also compares the field names
you reference against the committed fixtures and warns about any name that appears in no document.
That warning is how a typo shows up before it reaches a page as a silently shorter sentence.

The app checks the same things at compile time, so a broken config fails the build.

## 4. When the source renames a field

Releases rename fields. When one does, do not change the config to the new name only. Older
documents still use the old one. Add an alias instead:

```elixir
aliases: [
  %{field: "regulatory_approvals", as: "FDA_regulatory_approvals"}
]
```

Write `regulatory_approvals` everywhere in the config. Each document is read with the canonical
name first and the alias second, so one config renders both spellings.

Add `versions: "<2.0.0"` only when you are sure a rename happened at a clean version boundary. In
the drug approvals KG it did not: two dumps of the same version spell the field differently, which
is why that config's alias has no version range.

## Worked example

`kgs/drug_approvals.exs` is the most complete config and is tested against real stored documents.
Read it next to the [config reference](config-reference.md).
