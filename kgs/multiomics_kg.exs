# Display config for the Multiomics KG.
#
# Ported from KGinfo/Multiomics_KG.pl. The `name` must match the <name> part of the version key
# the CLI loads under (multiomics-kg-1.12.0); it is a contract with whoever runs the ingest.
%{
  name: "multiomics-kg",
  display_name: "Multiomics KG",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-KP",
  description: """
  The Multiomics KP asserts relationships between omics features and disease, derived from
  published cohort studies. Association strength and significance come from the source
  publication rather than from a Translator inference.
  """,
  feedback_repo: "https://github.com/TranslatorBots/multiomicsKP",
  slots: %{
    "subject" => {:link, "subject_name", "subject"},
    "object" => {:link, "object_name", "object"},

    # The Perl read the direction off the sign of relationship_strength and then chose between
    # two phrasings depending on whether the predicate was "causes".
    # Each optional word carries its own leading space, so an absent strength leaves no gap:
    # "is correlated with", never "is  correlated with". direction_word is the bare form for the
    # start of the causes phrasing.
    "direction" =>
      {:if, [{:lt, "relationship_strength", 0}], " negatively",
       {:if, [{:gt, "relationship_strength", 0}], " positively"}},
    "direction_word" =>
      {:if, [{:lt, "relationship_strength", 0}], "negatively ",
       {:if, [{:gt, "relationship_strength", 0}], "positively "}},

    # "(but not significantly)" was appended inline in the legacy sentence rather than left to the
    # evidence panel, because it changes what the sentence claims.
    "significance" => {:if, [{:eq, "significant", "NO"}], " (but not significantly)"},
    "significance_word" => {:if, [{:eq, "significant", "NO"}], "(but not significantly) "},
    "predicate_words" => {:humanize, "predicate"},
    "relation" =>
      {:if, [{:eq, "predicate", "biolink:causes"}], "{direction_word}{significance_word}affects",
       "is{direction}{significance} {predicate_words}"},
    "qualifier" =>
      {:if, [{:present, "qualifier_domain"}], " with {qualifier_domain} = {qualifier_value}"},
    "strength" => {:number, "relationship_strength", :sig2},
    "sample_size" => {:number, "sample_size", :int},
    "p_value" => {:number, "p_value", :sig2},
    "correction" => {:humanize, "multiple_testing_correction_method"},
    "curator" => {:field, "config_curator_name"},
    "publication" => {:link, "publication", "publication"},
    "sheet" => {:default, "sheet_name", "the supplementary materials"},
    "method" => {:humanize, "assertion_method"}
  },
  title: "{subject_name} — {object_name}",
  edge: "This relationship represents the finding that {subject} {relation} {object}.",
  evidence: [
    %{
      label: "Strength of association",
      value: "{method}: {strength}",
      if: [{:present, "relationship_strength"}]
    },
    %{
      label: "p-value",
      value:
        {:if, [{:present, "multiple_testing_correction_method"}],
         "{p_value} (corrected, {correction})", "{p_value}"},
      if: [{:present, "p_value"}]
    },
    %{
      label: "Cohort size",
      value: "N = {sample_size} individuals",
      if: [{:gt, "sample_size", 0}]
    },
    %{label: "Stratification", value: "{qualifier}", if: [{:present, "qualifier_domain"}]},
    %{
      label: "Reported in",
      value: "{sheet}, {publication}",
      if: [{:any, [{:present, "sheet_name"}, {:present, "publication"}]}]
    },
    %{label: "Curated by", value: "{curator}", if: [{:present, "config_curator_name"}]}
  ]
}
