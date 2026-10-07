# Display config for the DrugApprovals KP.
#
# Ported from the legacy KGinfo/drug_approvals.pl, field by field, against real DAKP documents
# rather than from memory: the field names below were confirmed by decoding the committed contract
# fixtures (cli/testdata/contract/docs.ndjson). Two of the legacy behaviours are deliberately not
# reproduced — see the notes on `relation` and on the missing-name fallback.
%{
  # Everything this file does not declare is inherited from kgs/_default.exs: the generic KGX
  # rendering (names, kinds, provenance, the qualifier stack, sources). Only DAKP's specifics
  # live here.
  extends: "default",

  # The canonical identifier: the infores the graph is registered under. Its slug — the same
  # name without the `infores:` prefix — is what gets stored on documents and put in URLs.
  name: "infores:drugapprovals-kp",
  display_name: "DrugApprovals KP",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP",
  # One flowing string: the page wraps it to the article measure. Hard line breaks in a
  # heredoc would survive white-space handling and print as a ragged narrow column.
  description:
    "The DrugApprovals KP curates assertions of FDA- and EMA-approved treatment relationships, usages observed in FAERS and Health Canada's Canada Vigilance database and applied to treat, and contraindications text-mined from DailyMed labeling; these assertions are derived from DailyMed, Drugs@FDA, FAERS, Canada Vigilance, and the EMA medicines registry.",
  feedback_repo: "https://github.com/glusman-team/dakp",

  # The newest release this config was written against. The page tags that version as the
  # latest one in the header and on the version timeline, so a reader never has to diff two
  # versions to know which one reflects the current knowledge graph.
  latest_version: "1.23.4",

  # Known issues: each entry states one defect, then lists every release where it occurs
  # (:versions, requirements in the {:version, ...} syntax — a bare version matches exactly).
  # The description is the curator's own words about what is wrong, shown verbatim in a
  # notice when any of those releases is displayed.
  known_errors: [
    %{
      description:
        "The per-edge linkouts on db.systemsbiology.net do not exist for this version.",
      versions: ["1.23.3"]
    }
  ],

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
         # applied_to_treat is an observed usage rather than an approval, so the claim
         # takes the predicate's own wording ("has been applied to treat") instead of the
         # generic "used for" fallback. When the source stored the usage as off-label, the
         # headline says so and the evidence paragraph drops its status sentence — one
         # statement of the fact, in the loudest place.
         "biolink:applied_to_treat" =>
           {:if, [{:eq, "clinical_approval_status", "off_label_use"}],
            "was applied off label to treat", "has been applied to treat"},
         # Contraindication is a family of predicates, not one value, so it is matched rather than
         # listed: biolink:contraindicated_in, biolink:contraindicated_for, and any later addition.
         :default =>
           {:if, [{:matches, "predicate", "^biolink:contraindicated"}],
            "is contraindicated for patients with", "has been used for {verb}"}
       }},

    # The text relationship line names each node with its linkout; the CURIE itself is an
    # identifier, not part of the claim, so it sits behind a "curie" chip that reveals it in
    # place — one click to see or copy, no parentheses breaking the sentence.
    "subject_curie" => {:fold, "curie", {:link, "subject", "subject"}},
    "object_curie" => {:fold, "curie", {:link, "object", "object"}},

    # Inside a {:list, "sources", ...} element, slots resolve against the element itself, so
    # {infores} links this source's own resource_id into the Translator information resource
    # registry catalog, and {role} is this source's role, not the edge's.
    # The RIG's supporting_data_source_info names each source in words a reader knows
    # (DailyMed, FAERS, the EMA medicines registry); the name links to the source's page in
    # the information resource registry where one is registered. The legacy slug
    # multiomics-drugapprovals moved to drugapprovals-kp, but stored edges from before the
    # rename still carry the legacy id, so both branches name the same page;
    # the RIG's infores:ema, infores:epar and infores:canada-vigilance are not in the registry
    # at all, so those link to the agencies' own pages instead of a 404. Unknown sources fall
    # back to the linked CURIE.
    "infores" =>
      {:pick, "resource_id",
       %{
         # Stored edges from before the rename carry the legacy id; both name it the same.
         "infores:drugapprovals-kp" =>
           {:url,
            "https://biolink.github.io/information-resource-registry/resources/drugapprovals-kp/",
            "DrugApprovals KP"},
         "infores:multiomics-drugapprovals" =>
           {:url,
            "https://biolink.github.io/information-resource-registry/resources/drugapprovals-kp/",
            "DrugApprovals KP"},
         "infores:dailymed" =>
           {:url, "https://biolink.github.io/information-resource-registry/resources/dailymed/",
            "DailyMed"},
         "infores:faers" =>
           {:url, "https://biolink.github.io/information-resource-registry/resources/faers/",
            "the FDA Adverse Event Reporting System (FAERS)"},
         "infores:ema" =>
           {:url, "https://www.ema.europa.eu/en/medicines", "the EMA medicines registry"},
         "infores:epar" =>
           {:url, "https://www.ema.europa.eu/en/medicines/download-medicine-data", "the EMA EPAR"},
         "infores:canada-vigilance" =>
           {:url,
            "https://www.canada.ca/en/health-canada/services/drugs-health-products/medeffect-canada/adverse-reaction-database.html",
            "Canada Vigilance Adverse Reaction Database"},
         :default => {:link, "resource_id", "resource_id"}
       }},
    # The legacy page printed approval statuses verbatim ("off_label_use"). Naming them in plain
    # language is the same fact in the reader's vocabulary; an unlisted status still renders,
    # humanized, rather than disappearing.
    "status" =>
      {:pick, "clinical_approval_status",
       %{
         "approved_for_condition" => "approved for the indicated condition",
         "off_label_use" => "observed off-label use",
         "contraindicated" => "contraindicated",
         "not_provided" => "unspecified",
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
    # The searches run over every name the source used for each concept — the preferred name
    # plus each pipe-delimited original — as a quoted-phrase OR group, so a label that only
    # spells the name the way the source text did is still found. The link text stays the
    # preferred name, so what the reader reads is unaffected.
    "subject_query" => {:or_query, "subject_name", "original_subject"},
    "object_query" => {:or_query, "object_name", "original_object"},
    "search_subject" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query={subject_query}",
       "labels mentioning {subject_name}"},
    "search_object" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query={object_query}",
       "labels mentioning {object_name}"},
    "search_both" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?adv=1&labeltype=all&query=({subject_query})+AND+34067-9:({object_query})",
       "labels mentioning both {subject_name} and {object_name}"},

    # Provenance names the integrator once and lists what it integrated: the primary source
    # is DAKP itself, so it renders as nothing inside the list (empty elements are dropped)
    # and the sentence names the supporting sources with their linkouts.
    "supporting_source" =>
      {:pick, "resource_role",
       %{
         "primary_knowledge_source" => "",
         :default => "{infores}"
       }},
    "supporting_sources" => {:list, "sources", "{supporting_source}", ", ", 5, "and"},
    "dakp" =>
      {:strong,
       {:url,
        "https://biolink.github.io/information-resource-registry/resources/drugapprovals-kp/",
        "DrugApprovals KP"}},
    "generated_by" =>
      {:if, [{:present, "sources"}],
       "This association was generated by {dakp}, which integrates {supporting_sources}."}
  },
  title: "{subject_name} and {object_name}",
  edge:
    "This relationship states that {subject} {relation} {object}{context}{qualifier_anatomical}{qualifier_frequency}{qualifier_population}{qualifier_sex}{qualifier_temporal}.",

  # The legacy text relationship, in full sentences: the claim first, with identifiers and
  # categories inline, then the provenance in words. It scales to any qualifier the config
  # knows, where a subject/predicate/object diagram card can only ever show three.
  # A plain string, not a heredoc: a heredoc's closing newline would print as a blank line
  # under white-space: pre-line. Two sentences in one paragraph: the claim, then how it
  # entered the graph (parallel phrasing, humanized values, no duplicate parentheses). The
  # raw field names never surface: "its agent_type is manual_validation_of_automated_agent"
  # taught the reader a storage key; "generated by an automated agent and validated by a
  # human curator" teaches them the fact.
  relationship:
    "{subject}{subject_curie}, a {subject_kind}, {relation} {object}{object_curie}, a {object_kind}{context}{qualifier_anatomical}{qualifier_frequency}{qualifier_population}{qualifier_sex}{qualifier_temporal}. " <>
      "{provenance} {generated_by}",

  # The evidence block, as prose. The legacy page ran these same facts as optional lines —
  # "Number of FAERS cases reporting this usage: 12", "Relevant approvals: NDA202155" — and the
  # instinct stands: a sentence carries its own meaning, where a table row labelled
  # "Assertion method (agent_type)" asked the reader to decode a storage key. Each entry is one
  # sentence; the :if conditions drop the ones the document cannot support; the renderer joins
  # what survives into one paragraph.
  evidence: [
    %{
      value:
        {:pick, "clinical_approval_status",
         %{
           "approved_for_condition" =>
             "DrugApprovals KP asserts this association is approved for the indicated condition.",
           # Stated in the headline ("was applied off label to treat"); an empty render
           # drops the sentence here rather than repeating it in quieter type.
           "off_label_use" => "",
           "contraindicated" => "DrugApprovals KP asserts this association is contraindicated.",
           "not_provided" =>
             "DrugApprovals KP does not specify the approval status of this association.",
           :default => "DrugApprovals KP characterizes this association as {status}."
         }},
      if: [{:present, "clinical_approval_status"}]
    },
    # The legacy page never let a reader wonder whether approvals were missing or merely
    # unrendered: the product-labels line always printed, falling back to "None.". Both facts
    # stay stated either way — the exact numbers and set ids when the source has them, an
    # explicit none when it does not.
    %{
      value:
        {:if, [{:present, "regulatory_approvals"}],
         "Regulatory approval for this association is documented under {approvals}.",
         "No FDA application numbers are recorded for this association."}
    },
    # Legacy: "Number of FAERS cases reporting this usage: 12".
    %{
      # The count is computed in the DAKP pipeline as the union of distinct case ids across
      # FAERS and Canada Vigilance spontaneous reports (both aggregation paths land in one
      # table and Tablassert's uuid merge recomputes number_of_cases as the union), so the
      # sentence names both databases. EMA contributes no cases: it feeds the approval and
      # contraindication tables. DailyMed corroborates labels, not cases. The full names are
      # established by the first paragraph's sources sentence, so acronyms suffice here.
      value: "FAERS and Canada Vigilance record {number_of_cases} cases of this usage.",
      if: [{:present, "number_of_cases"}]
    },
    # Legacy: "Relevant product labels: 1, 2", each SPL set id linked into DailyMed.
    %{
      value:
        {:if, [{:present, "publications"}],
         "This association is documented on the product labels {labels}.",
         "No structured-product-label set identifiers are recorded for this association."}
    }
  ],

  # Helper text the reader acts on, not a fact about the edge: the DailyMed searches the
  # legacy page ended with ("Search labels for $subject, labels for $subject and $object").
  # It renders as its own paragraph beneath the evidence paragraph, so an action item does
  # not dilute the evidence argument.
  footnote: "Try searching DailyMed for {search_subject}, {search_object}, or {search_both}."
}
