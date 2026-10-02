# Display config for the Wellness KG.
#
# Ported from KGinfo/wellness_kg.pl. This KG is unusual in that both endpoints are blood
# measurements, so the sentence talks about "the level of X observed in blood" rather than a
# subject acting on an object. Field names are capitalized in the source data
# (Strength_of_relationship, Bonferroni_pval) and are kept verbatim: a config that "fixed" the
# casing would silently render nothing.
%{
  name: "wellness-kg",
  display_name: "Wellness KG",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Wellness-KP",
  description: """
  The Wellness KP asserts correlations between blood-measured analytes and clinical or wellness
  measures, derived from a large longitudinal consumer-health cohort.
  """,
  feedback_repo: "https://github.com/TranslatorBots/wellnessKP",
  slots: %{
    "subject" => {:link, "subject_name", "subject"},
    "object" => {:link, "object_name", "object"},
    "direction" => {:if, [{:gte, "Strength_of_relationship", 0}], "positively", "negatively"},
    # The legacy page linked the word "correlated" to the relation CURIE, which reads oddly and
    # points at a term the reviewer already has in the sentence; the label is kept as plain text.
    "relation" => {:default, "relation", "correlated"},
    "strength" => {:field, "Strength_of_relationship"},
    "p_value" => {:field, "Bonferroni_pval"},
    "sample_size" => {:field, "N"},
    "relationship_type" => {:field, "Type_of_relationship"},
    "stratification" =>
      {:if, [{:present, "qualifier_domain"}], " with {qualifier_domain} = {qualifier_value}"}
  },
  title: "{subject_name} — {object_name}",
  edge:
    "This relationship represents the finding that the level of {subject} observed in blood is {direction} {relation} with the level of {object}{stratification}.",
  evidence: [
    %{
      label: "Strength of correlation",
      value: "{relationship_type}: {strength}",
      if: [{:present, "Strength_of_relationship"}]
    },
    %{
      label: "Bonferroni-corrected p-value",
      value: "{p_value}",
      if: [{:present, "Bonferroni_pval"}]
    },
    %{label: "Cohort size", value: "N = {sample_size} individuals", if: [{:present, "N"}]},
    %{label: "Stratification", value: "{stratification}", if: [{:present, "qualifier_domain"}]}
  ]
}
