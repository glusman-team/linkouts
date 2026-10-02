# Display config for the Microbiome KG.
#
# Ported from KGinfo/Microbiome_KG.pl, which shares the Multiomics sentence shape but not its
# significance qualifier. Field names are the ones that Perl read, which is the best available
# evidence: no microbiome dump is in the local DAKP sample, so unlike drug approvals this config
# has not been exercised against real documents.
%{
  name: "microbiome-kg",
  display_name: "Microbiome KG",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Microbiome-KP",
  description: """
  The Microbiome KP asserts relationships between microbial taxa or their functions and host
  phenotypes, curated from published cohort and case-control studies.
  """,
  feedback_repo: "https://github.com/TranslatorBots/microbiomeKP",
  slots: %{
    "subject" => {:link, "subject_name", "subject"},
    "object" => {:link, "object_name", "object"},
    "direction" =>
      {:if, [{:lt, "relationship_strength", 0}], "negatively",
       {:if, [{:gt, "relationship_strength", 0}], "positively"}},
    "predicate_words" => {:humanize, "predicate"},
    "relation" =>
      {:if, [{:eq, "predicate", "biolink:causes"}], "{direction} affects",
       "is {direction} {predicate_words}"},
    "strength" => {:number, "relationship_strength", :sig2},
    "sample_size" => {:number, "sample_size", :int},
    "p_value" => {:number, "p_value", :sig2},
    "correction" => {:humanize, "multiple_testing_correction_method"},
    "method" => {:humanize, "assertion_method"},
    "sheet" => {:default, "sheet_name", "the supplementary materials"},
    "row" => {:field, "source_row_number"},
    "publication" => {:link, "publication", "publication"},
    "curator" => {:field, "config_curator_name"}
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
    %{
      label: "Reported in",
      value: "{sheet} (row {row}), {publication}",
      if: [{:any, [{:present, "sheet_name"}, {:present, "publication"}]}]
    },
    %{label: "Curated by", value: "{curator}", if: [{:present, "config_curator_name"}]}
  ]
}
