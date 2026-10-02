# Display config for the Clinical Trials KG.
#
# Ported from KGinfo/clinical_trials.pl. One deliberate omission: the legacy evidence block
# rendered a per-trial table from `supporting_trials`, a map of trial records keyed by NCT id with
# nested phase, start date and testing-status fields. Iterating a map of nested records is outside
# this grammar, and adding a nested-record form to serve one KG would complicate every other
# config. The trial ids are linked instead, which carries the reviewer to clinicaltrials.gov —
# the detail table was a convenience, not the evidence.
#
# The boxed-warning note is kept: it is a safety-relevant qualifier, and dropping it would make
# the page less cautious than the one it replaces.
%{
  name: "clinical-trials-kg",
  display_name: "Clinical Trials KG",
  url: "https://github.com/NCATSTranslator/Translator-All/wiki/Clinical-Trials-KP",
  description: """
  The Clinical Trials KP asserts relationships between drugs and diseases based on their appearance
  in clinical trial records, distinguishing interventions that were tested from those merely
  mentioned.
  """,
  feedback_repo: "https://github.com/TranslatorBots/clinicaltrialsKP",

  # Aliases are tried in order after the canonical name, which is how the legacy
  # `$value->{'unii'} || $value->{'subject'}` preference is expressed without inventing a field.
  aliases: [
    %{field: "subject_curie", as: "unii"},
    %{field: "subject_curie", as: "subject"}
  ],
  slots: %{
    # The Perl preferred `unii` over `subject` for the subject linkout. Expressed as an alias
    # chain below, so this slot reads a canonical name and fetch/2 walks unii then subject.
    "subject" => {:link, "subject_name", "subject_curie"},
    "object" => {:link, "object_name", "object"},
    "trial_count" => {:count, "supporting_trial_ids"},
    "trials_word" =>
      {:if, [{:count_gt, "supporting_trial_ids", 1}], "{trial_count} clinical trials",
       "a clinical trial"},

    # Three phrasings, in the legacy precedence: treats, then tested, then merely mentioned.
    "relation" =>
      {:pick, "predicate",
       %{
         "biolink:treats" => "treats",
         :default =>
           {:if, [{:eq, "tested_intervention", "yes"}], "was tested in {trials_word} for",
            "was mentioned among the interventions in {trials_word} for"}
       }},
    "boxed_note" =>
      {:if,
       [{:any, [{:eq, "intervention_boxed_warning", "t"}, {:eq, "subject_boxed_warning", "t"}]}],
       " Note: some drug approvals including {subject_name} have a boxed warning."},
    "trials" =>
      {:list, "supporting_trial_ids", {:url, "https://clinicaltrials.gov/study/{self}", "{self}"},
       ", "}
  },
  title: "{subject_name} — {object_name}",
  edge: "This relationship states that {subject} {relation} {object}.{boxed_note}",
  evidence: [
    %{
      label: "Approval basis",
      value: "The presence of Phase 4 clinical trials indicates FDA approval for this treatment.",
      if: [{:eq, "predicate", "biolink:treats"}]
    },
    %{label: "Supporting trials", value: "{trials}", if: [{:present, "supporting_trial_ids"}]},
    %{
      label: "Tested as an intervention",
      value: {:field, "tested_intervention"},
      if: [{:present, "tested_intervention"}]
    },
    %{
      label: "Boxed warning",
      value: {:default, "intervention_boxed_warning", {:field, "subject_boxed_warning"}},
      if: [
        {:any, [{:present, "intervention_boxed_warning"}, {:present, "subject_boxed_warning"}]}
      ]
    }
  ]
}
