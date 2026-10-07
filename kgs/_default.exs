# The default display config, used two ways:
#
#   * as the base any KG config can `extends: "default"` — slots merge per slot name, aliases
#     append, other keys are replaced wholesale (the way Tablassert's table configs override
#     sections);
#   * as the fallback for a stored KG with no config of its own, so ingesting a random KGX
#     dump renders a readable page before anyone writes a single override.
#
# The user-facing documentation lives in the ExDoc guide "The default config"
# (docs/pages/the-default-config.md): roles, slot reference, worked examples, merge rules.
# Keep the two in sync when changing what a slot renders.
# It covers the standard KGX / Biolink surface and follows the same rigor the DrugApprovals
# config was ported with: a name renders when the dump carries one and the CURIE otherwise; a
# missing field drops its clause instead of printing an empty frame (every qualifier falls back
# to a labelled CURIE chip, not to nothing); biolink terms read as words and link to the
# model's own docs; provenance is stated in the reader's vocabulary with the humanized value as
# the fallback for values this config does not enumerate. A KG config then overrides whatever is
# specific to it — predicate prose, field quirks, sentence structure — without restating any of
# this.
%{
  # Not a real KG name: it matches nothing, so only `extends` and the for_key fallback reach it.
  name: "default",
  slots: %{
    # A node renders as its name when the dump carries one, as the CURIE itself otherwise.
    "subject_display" => {:default, "subject_name", {:field, "subject"}},
    "object_display" => {:default, "object_name", {:field, "object"}},

    # The predicate reads as words ("biolink:treats" -> "treats"); a KG config overrides this
    # with per-predicate prose where the generic verb is not the claim a reader should see.
    "relation" => {:humanize, "predicate"},

    # Categories are biolink terms: words in prose, linked to the term's own page in the
    # model's docs, which names every term by its local id. Absent categories drop their
    # clause — "a ." must never print.
    "subject_kind_words" => {:humanize, "subject_category"},
    "subject_kind_local" => {:local, "subject_category"},
    "subject_kind" =>
      {:url, "https://biolink.github.io/biolink-model/{subject_kind_local}/",
       "{subject_kind_words}"},
    "subject_kind_clause" => {:if, [{:present, "subject_category"}], ", a {subject_kind},"},
    "object_kind_words" => {:humanize, "object_category"},
    "object_kind_local" => {:local, "object_category"},
    "object_kind" =>
      {:url, "https://biolink.github.io/biolink-model/{object_kind_local}/",
       "{object_kind_words}"},
    "object_kind_clause" => {:if, [{:present, "object_category"}], ", a {object_kind}"},

    # Provenance, in the reader's vocabulary. knowledge_level and agent_type are standard KGX
    # fields with standard enum values, so the enumerated wording is generic; values this
    # config does not list fall back to the humanized value rather than disappearing.
    "agent_type_prose" => {:humanize, "agent_type"},
    "knowledge_level_prose" => {:humanize, "knowledge_level"},
    "provenance" =>
      {:pick, "knowledge_level",
       %{
         "knowledge_assertion" =>
           {:pick, "agent_type",
            %{
              "manual_validation_of_automated_agent" =>
                "This assertion is machine-generated and human-validated.",
              "automated_agent" => "This assertion is machine-generated.",
              "manual_agent" => "This assertion is human-curated.",
              "not_provided" =>
                "The primary knowledge source does not document how this assertion was produced.",
              :default => "This assertion was produced by {agent_type_prose}."
            }},
         "observation" =>
           {:pick, "agent_type",
            %{
              "manual_validation_of_automated_agent" =>
                "This observation is machine generated. The entire dataset underwent manual QC with some human validation.",
              "automated_agent" => "This observation is machine-generated.",
              "manual_agent" => "This observation is human-curated.",
              "not_provided" =>
                "The primary knowledge source does not document how this observation was produced.",
              :default => "This observation was recorded by {agent_type_prose}."
            }},
         :default =>
           {:pick, "agent_type",
            %{
              "manual_validation_of_automated_agent" =>
                "This statement is machine-generated and human-validated.",
              "automated_agent" => "This statement is machine-generated.",
              "manual_agent" => "This statement is human-curated.",
              "not_provided" => "The provenance of this statement is not recorded.",
              :default =>
                {:if, [{:present, "agent_type"}],
                 "The assertion method of this statement is {agent_type_prose}.",
                 "The provenance of this statement is not recorded."}
            }}
       }},

    # The qualifier stack: DAKP's supporting_text log convention ("original_{qualifier}: value")
    # gives the readable source phrase, framed so the sentence flows, with rewordings repairing
    # fragments ("dosage" alone, a singular "adult"); the labelled CURIE chip is the fallback
    # wherever the log line is missing. Gates are {:present} of the qualifier itself, so a KG
    # that populates these fields at any version renders them.
    "qualifier_anatomical" =>
      {:if, [{:present, "anatomical_context_qualifier"}],
       {:supporting, "original_anatomical_context_qualifier", ", in the ", "", %{},
        ", anatomical context {anatomical_qualifier_link}"}},
    "qualifier_frequency" =>
      {:if, [{:present, "frequency_qualifier"}],
       {:supporting, "original_frequency_qualifier", ", dosed ", "",
        %{
          "dosage" => "at the labeled dosage",
          "daily dosage" => "at the labeled daily dosage",
          "low-dose maintenance therapy" => "on low-dose maintenance therapy"
        }, ", frequency {frequency_qualifier_link}"}},
    "qualifier_population" =>
      {:if, [{:present, "population_context_qualifier"}],
       {:supporting, "original_population_context_qualifier", ", in ", "", %{},
        ", population context {population_qualifier_link}"}},
    "qualifier_sex" =>
      {:if, [{:present, "sex_qualifier"}],
       {:supporting, "original_sex_qualifier", ", in ", "",
        %{
          "adult" => "adults",
          "woman" => "women",
          "man" => "men",
          "child" => "children",
          "female" => "females",
          "male" => "males"
        }, ", sex {sex_qualifier_link}"}},
    "qualifier_temporal" =>
      {:if, [{:present, "temporal_context_qualifier"}],
       {:supporting, "original_temporal_context_qualifier", ", ", "",
        %{
          "extended period of time" => "over an extended period of time",
          "7 days" => "for 7 days",
          "preoperatively" => "preoperatively",
          "postoperatively" => "postoperatively"
        }, ", temporal context {temporal_qualifier_link}"}},
    "anatomical_qualifier_link" =>
      {:link, "anatomical_context_qualifier", "anatomical_context_qualifier"},
    "frequency_qualifier_link" => {:link, "frequency_qualifier", "frequency_qualifier"},
    "population_qualifier_link" =>
      {:link, "population_context_qualifier", "population_context_qualifier"},
    "sex_qualifier_link" => {:link, "sex_qualifier", "sex_qualifier"},
    "temporal_qualifier_link" =>
      {:link, "temporal_context_qualifier", "temporal_context_qualifier"},

    # The disease-context qualifier renders only when a displayable name exists — a present
    # CURIE with no name would print " in the context of " with nothing after it.
    "context" =>
      {:if, [{:present, "disease_context_qualifier_name"}], " in the context of {qualifier}"},
    "qualifier" => {:link, "disease_context_qualifier_name", "disease_context_qualifier"},

    # KGX provenance is a standard shape (resource_id + resource_role per source), so the
    # sentence inherits everywhere: primary source bold, the rest plain, five named then an
    # "and". Each resource_id links through the CURIE prefixes; a KG config overrides {infores}
    # with named branches where it knows better URLs.
    "infores" => {:link, "resource_id", "resource_id"},
    "source" =>
      {:pick, "resource_role",
       %{
         "primary_knowledge_source" => {:strong, "{infores}"},
         :default => "{infores}"
       }},
    "sources" => {:list, "sources", "{source}", ", ", 5, "and"}
  },
  title: "{subject_display} and {object_display}",
  edge:
    "This relationship states that {subject_display} {relation} {object_display}{context}{qualifier_anatomical}{qualifier_frequency}{qualifier_population}{qualifier_sex}{qualifier_temporal}.",

  # Same shape as the DrugApprovals page: the claim with categories inline, then the
  # provenance. A plain string, not a heredoc — the closing newline would print as a blank
  # line under white-space: pre-line.
  relationship:
    "{subject_display}{subject_kind_clause} {relation} {object_display}{object_kind_clause}{context}{qualifier_anatomical}{qualifier_frequency}{qualifier_population}{qualifier_sex}{qualifier_temporal}. " <>
      "{provenance}",

  # The one sentence every KGX dump with sources supports; a KG config appends its own
  # sections (approval status, case counts) above it.
  evidence: [
    %{
      value: "This association is derived from {sources}.",
      if: [{:present, "sources"}]
    }
  ]
}
