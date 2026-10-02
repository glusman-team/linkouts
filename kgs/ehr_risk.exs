# Display config for the EHR risk KG.
#
# Ported from KGinfo/ehr_risk.pl, which served two different sentence shapes off one file, chosen
# by the KG_type field: risk associations, or drug-treats assertions. Both are kept, because the
# legacy dispatch was data-driven and dropping one would blank those edges.
%{
  name: "ehr-risk-kg",
  display_name: "EHR Risk KG",
  url:
    "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Clinical-Connections-KP",
  description: """
  The EHR risk KG asserts associations between features observed in electronic health records and
  outcomes, with effect sizes and p-values computed over a patient cohort. It also carries
  drug-treats assertions derived from the same clinical data.
  """,
  feedback_repo: "https://github.com/TranslatorBots/multiomicsKP",
  slots: %{
    "subject" => {:link, "subject_name", "subject"},
    "object" => {:link, "object_name", "object"},
    "direction" => {:if, [{:lt, "feature_coefficient", 0}], "negatively", "positively"},
    "coefficient" => {:field, "feature_coefficient"},
    "p_value" => {:field, "p_value_readable"},
    "patient_count" => {:field, "positive_patient_count"}
  },
  title: "{subject_name} — {object_name}",

  # KG_type selects the sentence, exactly as the legacy code did.
  edge:
    {:pick, "KG_type",
     %{
       "EHR risk KG" =>
         "This relationship represents the finding that {subject} may be {direction} associated with {object}.",
       :default =>
         "This relationship represents the finding that drug {subject} may treat {object}."
     }},
  evidence: [
    %{
      label: "Strength of correlation",
      value: "Log-transformed odds ratio: {coefficient}",
      if: [{:present, "feature_coefficient"}]
    },
    %{
      label: "Bonferroni-corrected p-value",
      value: "{p_value}",
      if: [{:present, "p_value_readable"}]
    },
    %{
      label: "Cohort size",
      value: "N = {patient_count} individuals with {object_name}",
      if: [{:present, "positive_patient_count"}]
    }
  ]
}
