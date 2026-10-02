# Display config for the Multiomics Drug Approvals KG.
#
# Ported from the legacy KGinfo/drug_approvals.pl, field by field, against real DAKP documents
# rather than from memory: the field names below were confirmed by decoding the committed contract
# fixtures (cli/testdata/contract/docs.ndjson). Two of the legacy behaviours are deliberately not
# reproduced — see the notes on `relation` and on the missing-name fallback.
%{
  name: "drug-approvals-kg",
  display_name: "Multiomics Drug Approvals",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP",
  description: """
  The Multiomics Drug Approvals KP provides assertions about regulatory approvals of drug
  interventions for treating diseases, and observations of off-label use and contraindications.
  Assertions are derived from DailyMed and the FDA's adverse-event reporting system (FAERS);
  contraindication assertions come from the MATRIX project.
  """,
  feedback_repo: "https://github.com/multiomicsKP/drug_approvals_kp",

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
    "approvals" => {:list, "regulatory_approvals", {:link, "self", "self"}, ", "},
    "labels" => {:list, "publications", {:link, "self", "self"}, ", "},
    "search_subject" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query={subject_name}",
       "labels for {subject_name}"},
    "search_both" =>
      {:url,
       "https://dailymed.nlm.nih.gov/dailymed/search.cfm?adv=1&labeltype=all&query=({subject_name})+AND+34067-9:({object_name})",
       "labels for {subject_name} and {object_name}"},
    "sources" => {:list, "sources", "{resource_id}", ", "}
  },
  title: "{subject_name} — {object_name}",
  edge: "This relationship states that {subject} {relation} {object}{context}.",
  evidence: [
    %{
      label: "Number of FAERS cases reporting this usage",
      value: {:field, "number_of_cases"},
      if: [{:present, "number_of_cases"}]
    },
    %{
      label: "Relevant approvals",
      value: "{approvals}",
      if: [{:present, "regulatory_approvals"}]
    },
    %{
      label: "Relevant product labels",
      value: "{labels}",
      if: [{:present, "publications"}]
    },
    %{
      label: "Clinical approval status",
      value: {:field, "clinical_approval_status"},
      if: [{:present, "clinical_approval_status"}]
    },
    %{
      label: "Disease context",
      value: "{qualifier}",
      if: [{:present, "disease_context_qualifier"}]
    },
    %{
      label: "Knowledge level",
      value: {:field, "knowledge_level"},
      if: [{:present, "knowledge_level"}]
    },
    %{
      label: "Assertion method",
      value: {:field, "agent_type"},
      if: [{:present, "agent_type"}]
    },
    %{
      label: "Primary knowledge sources",
      value: "{sources}",
      if: [{:present, "sources"}]
    },
    %{
      label: "Search product labels",
      value: "{search_subject}, {search_both}."
    },
    %{
      label: "Notes from the source",
      value: {:list, "supporting_text", {:field, "self"}, "; "},
      if: [{:present, "supporting_text"}]
    }
  ]
}
