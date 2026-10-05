# Display config for the Drug Approvals KP.
#
# Ported from the legacy KGinfo/drug_approvals.pl, field by field, against real DAKP documents
# rather than from memory: the field names below were confirmed by decoding the committed contract
# fixtures (cli/testdata/contract/docs.ndjson). Two of the legacy behaviours are deliberately not
# reproduced — see the notes on `relation` and on the missing-name fallback.
%{
  # The canonical identifier: the infores the graph is registered under. Its slug — the same
  # name without the `infores:` prefix — is what gets stored on documents and put in URLs.
  name: "infores:drugapprovals-kp",
  display_name: "Drug Approvals KP",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP",
  # One flowing string: the page wraps it to the article measure. Hard line breaks in a
  # heredoc would survive white-space handling and print as a ragged narrow column.
  description:
    "The Drug Approvals KP provides assertions about regulatory approvals of drug interventions for treating diseases, and observations of off-label use and contraindications. Treatment assertions are derived from DailyMed, Drugs@FDA and the FDA's adverse-event reporting system (FAERS); contraindication assertions are mined from DailyMed label sections.",
  feedback_repo: "https://github.com/multiomicsKP/drug_approvals_kp",

  # The newest release this config was written against. The page tags that version as the
  # latest one in the header and on the version timeline, so a reader never has to diff two
  # versions to know which one reflects the current knowledge graph.
  latest_version: "1.16.0",

  # Measured drift, and messier than a rename: the 1.11.2 dump spells this
  # FDA_regulatory_approvals, and so does one 1.16.0 dump, while another 1.16.0 dump spells it
  # regulatory_approvals. A version gate would be wrong in both directions, so this is an unscoped
  # fallback: the canonical name wins when present, the old spelling is used otherwise.
  aliases: [
    %{field: "regulatory_approvals", as: "FDA_regulatory_approvals"}
  ],
  slots: %{
    "subject" => {:link, "subject_name", "subject"},
    "object" => {:link, "object_name", "object"},

    # The legacy code picked "preventing" vs "treating" off object_modifier, then the verb phrase
    # off the predicate. Same two decisions, expressed as data.
    "verb" =>
      {:pick, "object_modifier",
       %{
         "prevention" => "preventing",
         :default => "treating"
       }},
    "relation" =>
      {:pick, "predicate",
       %{
         "biolink:treats" => "has been approved for {verb}",
         # Contraindication is a family of predicates, not one value, so it is matched rather than
         # listed: biolink:contraindicated_in, biolink:contraindicated_for, and any later addition.
         :default =>
           {:if, [{:matches, "predicate", "^biolink:contraindicated"}],
            "is contraindicated for patients with", "has been used for {verb}"}
       }},

    # The legacy page only showed the disease-context qualifier for versions after 1.0.0, because
    # earlier releases did not populate it. The version gate is kept: an older document would
    # otherwise render an empty "in the context of".
    "context" =>
      {:if, [{:all, [{:version, ">1.0.0"}, {:present, "disease_context_qualifier"}]}],
       " in the context of {qualifier}"},
    "qualifier" => {:link, "disease_context_qualifier_name", "disease_context_qualifier"},

    # The text relationship line resolves each node's identifier to its own linkout, so the
    # CURIE is both visible and one click from the resolver, without a diagram card.
    "subject_curie" => {:link, "subject", "subject"},
    "object_curie" => {:link, "object", "object"},

    # The provenance sentence reads as prose but keeps the exact value beside it, so a
    # curator can check both at once.
    "agent_type_prose" => {:humanize, "agent_type"},

    # KGX knowledge_level values can carry underscores ("authoritative_knowledge_base");
    # prose renders them as words, exactly like agent_type.
    "knowledge_level_prose" => {:humanize, "knowledge_level"},

    # The categories and the predicate are biolink terms. In prose they read as words with no
    # prefix and no underscores; each also links to its own page in the model's docs, which
    # names every term by its local id — "biolink:applied_to_treat" lives at
    # biolink.github.io/biolink-model/applied_to_treat/.
    "subject_kind_words" => {:humanize, "subject_category"},
    "subject_kind_local" => {:local, "subject_category"},
    "subject_kind" =>
      {:url, "https://biolink.github.io/biolink-model/{subject_kind_local}/",
       "{subject_kind_words}"},
    "object_kind_words" => {:humanize, "object_category"},
    "object_kind_local" => {:local, "object_category"},
    "object_kind" =>
      {:url, "https://biolink.github.io/biolink-model/{object_kind_local}/",
       "{object_kind_words}"},
    "predicate_words" => {:humanize, "predicate"},
    "predicate_local" => {:local, "predicate"},
    "predicate_docs" =>
      {:url, "https://biolink.github.io/biolink-model/{predicate_local}/",
       "{predicate_words}"},

    # Inside a {:list, "sources", ...} element, slots resolve against the element itself, so
    # {role} is this source's role, not the edge's.
    "role" => {:humanize, "resource_role"},

    # The legacy page printed approval statuses verbatim ("off_label_use"). Naming them in plain
    # language is the same fact in the reader's vocabulary; an unlisted status still renders,
    # humanized, rather than disappearing.
    "status" =>
      {:pick, "clinical_approval_status",
       %{
         "approved_for_condition" => "approved for this condition",
         "off_label_use" => "observed off-label use",
         "contraindicated" => "contraindicated",
         "not_provided" => "not reported by the source",
         :default => {:humanize, "clinical_approval_status"}
       }},
    # Three read inline; a longer run folds behind a "show N more" toggle right where the list
    # sits, the way the legacy page kept its labelled lines to a row each.
    "approvals" => {:list, "regulatory_approvals", {:link, "self", "self"}, ", ", 3},

    # Inside a {:list, ...} element "self" is the element itself, so {:local, "self"} is the
    # element's id past its prefix — the exact SPL set id, shown and linked, where the legacy
    # page printed numbered links into DailyMed.
    "self_local" => {:local, "self"},
    "labels" =>
      {:list, "publications",
       {:url, "https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid={self_local}",
        "{self_local}"}, ", ", 3},
    "search_subject" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query={subject_name}",
       "labels mentioning {subject_name}"},
    "search_object" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query={object_name}",
       "labels mentioning {object_name}"},
    "search_both" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?adv=1&labeltype=all&query=({subject_name})+AND+34067-9:({object_name})",
       "labels mentioning both {subject_name} and {object_name}"},
    "sources" => {:list, "sources", "{resource_id} ({role})", ", ", 5}
  },
  title: "{subject_name} and {object_name}",
  edge: "This relationship states that {subject} {relation} {object}{context}.",

  # The legacy text relationship, in full sentences: the claim first, with identifiers and
  # categories inline, then the provenance sentence carrying the exact biolink predicate,
  # the knowledge level and the assertion method in words. It scales to any qualifier the
  # config knows, where a subject/predicate/object diagram card can only ever show three.
  # A plain string, not a heredoc: a heredoc's closing newline would print as a blank line
  # under white-space: pre-line. Two sentences in one paragraph: the claim first, then its
  # provenance in exact terms (parallel phrasing, humanized values, no duplicate parentheses).
  # The raw field names never surface: "its agent_type is manual_validation_of_automated_agent"
  # taught the reader a storage key; "its assertion method is manual validation of automated
  # agent" teaches them the fact.
  relationship:
    "{subject} ({subject_curie}), a {subject_kind}, {relation} {object} ({object_curie}), a {object_kind}{context}. " <>
      "Its predicate is {predicate_docs}, its knowledge level is {knowledge_level_prose}, and its assertion method is {agent_type_prose}.",

  # The evidence block, as prose. The legacy page ran these same facts as optional lines —
  # "Number of FAERS cases reporting this usage: 12", "Relevant approvals: NDA202155" — and the
  # instinct stands: a sentence carries its own meaning, where a table row labelled
  # "Assertion method (agent_type)" asked the reader to decode a storage key. Each entry is one
  # sentence; the :if conditions drop the ones the document cannot support; the renderer joins
  # what survives into one paragraph.
  evidence: [
    %{
      value: "The source classifies it as {status}.",
      if: [{:present, "clinical_approval_status"}]
    },
    # The legacy page never let a reader wonder whether approvals were missing or merely
    # unrendered: the product-labels line always printed, falling back to "None.". Both facts
    # stay stated either way — the exact numbers and set ids when the source has them, an
    # explicit none when it does not.
    %{
      value:
        {:if, [{:present, "regulatory_approvals"}],
         "It is covered by {approvals}.",
         "No FDA application numbers are recorded for it."}
    },
    # Legacy: "Number of FAERS cases reporting this usage: 12".
    %{
      value:
        "The FDA adverse-event reporting system (FAERS) holds {number_of_cases} cases reporting this usage.",
      if: [{:present, "number_of_cases"}]
    },
    # Legacy: "Relevant product labels: 1, 2", each SPL set id linked into DailyMed.
    %{
      value:
        {:if, [{:present, "publications"}],
         "It is documented on the product labels {labels}.",
         "No product-label SPL set ids are recorded for it."}
    },
    # Legacy named every source with its role; the parenthetical carries that here.
    %{
      value: "It comes from {sources}.",
      if: [{:present, "sources"}]
    },
    # Legacy: "Search labels for $subject, labels for $subject and $object."
    %{value: "On DailyMed, search {search_subject}, {search_object}, or {search_both}."}
  ]
}
