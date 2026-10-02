defmodule EdgeLinkouts.DisplayPortsTest do
  @moduledoc """
  The five KG configs ported from KGinfo/*.pl that have no local DAKP dump.

  Drug approvals is tested against real stored documents in display_test.exs. These five cannot
  be, because only the drug approvals KG is in the local DAKP sample. So each test builds a
  document from the field names the legacy Perl actually read, and asserts the sentence the
  legacy page would have produced. That proves the port is faithful to the Perl; it does not prove
  the field names still match current releases, which needs a real dump per KG. `mix
  linkouts.check` cross-checks field names against fixtures as soon as one is committed.
  """
  use ExUnit.Case, async: true

  alias EdgeLinkouts.Display
  alias EdgeLinkouts.Display.Segment

  defp sentence(kg, doc, version \\ "1.0.0") do
    config = Display.get(kg)
    assert config, "no display config for #{kg}"
    config |> Display.edge(doc, "#{kg}-#{version}") |> Segment.to_text()
  end

  defp evidence(kg, doc, version \\ "1.0.0") do
    config = Display.get(kg)

    config
    |> Display.evidence(doc, "#{kg}-#{version}")
    |> Map.new(&{Segment.to_text(&1.label), Segment.to_text(&1.value)})
  end

  defp pair(extra) do
    Map.merge(
      %{
        "subject" => "NCBIGene:7124",
        "subject_name" => "TNF",
        "object" => "MONDO:0005148",
        "object_name" => "type 2 diabetes"
      },
      extra
    )
  end

  test "all six legacy KGs have configs" do
    for kg <-
          ~w(drug-approvals-kg multiomics-kg microbiome-kg wellness-kg ehr-risk-kg clinical-trials-kg) do
      assert kg in Display.known(), "#{kg} has no display config"
    end
  end

  describe "multiomics" do
    test "a negative strength reads as negatively, and a non-causal predicate is humanized" do
      doc = pair(%{"predicate" => "biolink:correlated_with", "relationship_strength" => -0.42})

      assert sentence("multiomics-kg", doc) ==
               "This relationship represents the finding that TNF is negatively correlated with type 2 diabetes."
    end

    test "causes reads as affects, and non-significance qualifies the sentence itself" do
      doc =
        pair(%{
          "predicate" => "biolink:causes",
          "relationship_strength" => 1.3,
          "significant" => "NO"
        })

      # The legacy page put "(but not significantly)" in the sentence rather than the evidence
      # panel because it changes what the sentence claims.
      assert sentence("multiomics-kg", doc) ==
               "This relationship represents the finding that TNF positively (but not significantly) affects type 2 diabetes."
    end

    test "evidence formats the p-value and names the correction method" do
      doc =
        pair(%{
          "predicate" => "biolink:correlated_with",
          "relationship_strength" => 0.123456,
          "p_value" => 0.0000000012,
          "multiple_testing_correction_method" => "benjamini_hochberg",
          "sample_size" => 412.0
        })

      rows = evidence("multiomics-kg", doc)

      assert rows["p-value"] == "1.2e-9 (corrected, benjamini hochberg)"
      assert rows["Cohort size"] == "N = 412 individuals"
    end

    test "a zero sample size omits the cohort row instead of claiming N = 0" do
      doc = pair(%{"predicate" => "biolink:correlated_with", "sample_size" => 0})
      refute Map.has_key?(evidence("multiomics-kg", doc), "Cohort size")
    end
  end

  describe "microbiome" do
    test "shares the multiomics sentence shape without the significance clause" do
      doc =
        pair(%{
          "subject" => "NCBITaxon:816",
          "subject_name" => "Bacteroides",
          "predicate" => "biolink:associated_with",
          "relationship_strength" => 0.8,
          "significant" => "NO"
        })

      assert sentence("microbiome-kg", doc) ==
               "This relationship represents the finding that Bacteroides is positively associated with type 2 diabetes."
    end

    test "a missing sheet name falls back to the supplementary materials" do
      doc =
        pair(%{
          "predicate" => "biolink:associated_with",
          "publication" => "PMID:12345",
          "source_row_number" => 7
        })

      assert evidence("microbiome-kg", doc)["Reported in"] =~
               "the supplementary materials (row 7)"
    end
  end

  describe "wellness" do
    test "talks about blood levels and carries the stratification into the sentence" do
      doc =
        pair(%{
          "Strength_of_relationship" => -0.3,
          "qualifier_domain" => "sex",
          "qualifier_value" => "female"
        })

      assert sentence("wellness-kg", doc) ==
               "This relationship represents the finding that the level of TNF observed in blood is negatively correlated with the level of type 2 diabetes with sex = female."
    end

    test "zero strength reads as positively, matching the legacy >= 0 test" do
      assert sentence("wellness-kg", pair(%{"Strength_of_relationship" => 0})) =~
               "is positively correlated"
    end

    test "capitalized source field names are read verbatim" do
      doc = pair(%{"Strength_of_relationship" => 0.5, "Bonferroni_pval" => "3e-4", "N" => 900})
      rows = evidence("wellness-kg", doc)

      assert rows["Bonferroni-corrected p-value"] == "3e-4"
      assert rows["Cohort size"] == "N = 900 individuals"
    end
  end

  describe "ehr risk" do
    test "KG_type selects the risk sentence" do
      doc = pair(%{"KG_type" => "EHR risk KG", "feature_coefficient" => -1.1})

      assert sentence("ehr-risk-kg", doc) ==
               "This relationship represents the finding that TNF may be negatively associated with type 2 diabetes."
    end

    test "any other KG_type selects the treats sentence" do
      doc = pair(%{"KG_type" => "EHR treats KG", "feature_coefficient" => 2.0})

      assert sentence("ehr-risk-kg", doc) ==
               "This relationship represents the finding that drug TNF may treat type 2 diabetes."
    end

    test "evidence names the cohort by the object" do
      doc = pair(%{"KG_type" => "EHR risk KG", "positive_patient_count" => 1500})

      assert evidence("ehr-risk-kg", doc)["Cohort size"] ==
               "N = 1500 individuals with type 2 diabetes"
    end
  end

  describe "clinical trials" do
    defp trial(extra) do
      pair(%{"subject" => "CHEBI:6801", "subject_name" => "metformin"} |> Map.merge(extra))
    end

    test "treats reads as treats" do
      assert sentence("clinical-trials-kg", trial(%{"predicate" => "biolink:treats"})) ==
               "This relationship states that metformin treats type 2 diabetes."
    end

    test "tested interventions are pluralized by trial count" do
      doc =
        trial(%{
          "predicate" => "biolink:in_clinical_trials_for",
          "tested_intervention" => "yes",
          "supporting_trial_ids" => ["NCT01", "NCT02", "NCT03"]
        })

      assert sentence("clinical-trials-kg", doc) ==
               "This relationship states that metformin was tested in 3 clinical trials for type 2 diabetes."
    end

    test "a single untested trial reads as mentioned in a clinical trial" do
      doc =
        trial(%{
          "predicate" => "biolink:in_clinical_trials_for",
          "supporting_trial_ids" => ["NCT01"]
        })

      assert sentence("clinical-trials-kg", doc) ==
               "This relationship states that metformin was mentioned among the interventions in a clinical trial for type 2 diabetes."
    end

    test "the boxed warning note survives the port" do
      # Safety-relevant: dropping it would make the page less cautious than the one it replaces.
      doc = trial(%{"predicate" => "biolink:treats", "intervention_boxed_warning" => "t"})

      assert sentence("clinical-trials-kg", doc) =~
               "Note: some drug approvals including metformin have a boxed warning."
    end

    test "unii is preferred over subject for the subject linkout" do
      config = Display.get("clinical-trials-kg")
      doc = trial(%{"predicate" => "biolink:treats", "unii" => "UNII:9100L32L2N"})

      links =
        for {:link, href, label} <- Display.edge(config, doc, "clinical-trials-kg-1.0.0"),
            do: {label, href}

      assert {"metformin", "https://gsrs.ncats.nih.gov/ginas/app/beta/substances/9100L32L2N"} in links
    end

    test "without unii the subject CURIE is used" do
      config = Display.get("clinical-trials-kg")
      doc = trial(%{"predicate" => "biolink:treats"})

      links =
        for {:link, href, label} <- Display.edge(config, doc, "clinical-trials-kg-1.0.0"),
            do: {label, href}

      assert {"metformin", "https://www.ebi.ac.uk/chebi/beta/CHEBI:6801"} in links
    end

    test "trial ids link to clinicaltrials.gov" do
      config = Display.get("clinical-trials-kg")

      doc =
        trial(%{
          "predicate" => "biolink:treats",
          "supporting_trial_ids" => ["NCT00000001", "NCT00000002"]
        })

      row =
        config
        |> Display.evidence(doc, "clinical-trials-kg-1.0.0")
        |> Enum.find(&(Segment.to_text(&1.label) == "Supporting trials"))

      hrefs = for {:link, href, _} <- row.value, do: href

      assert hrefs == [
               "https://clinicaltrials.gov/study/NCT00000001",
               "https://clinicaltrials.gov/study/NCT00000002"
             ]
    end
  end

  describe "grammar edges" do
    test "a non-numeric strength does not crash the direction word" do
      # Sources spell a missing number "NA"; the condition is false rather than raising.
      doc = pair(%{"predicate" => "biolink:correlated_with", "relationship_strength" => "NA"})

      assert sentence("multiomics-kg", doc) =~ "TNF is  correlated with" or
               sentence("multiomics-kg", doc) =~ "TNF is correlated with"
    end

    test "an NA p-value renders as given rather than as a number" do
      doc = pair(%{"predicate" => "biolink:correlated_with", "p_value" => "NA"})
      assert evidence("multiomics-kg", doc)["p-value"] == "NA"
    end
  end
end
