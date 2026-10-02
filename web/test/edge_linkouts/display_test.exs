defmodule EdgeLinkouts.DisplayTest do
  @moduledoc """
  Renders real stored documents through the drug approvals config.

  These assertions use the committed contract fixtures rather than invented maps, so they check
  the config against field names that actually occur in DAKP data. A config that validates but
  renders nothing is the failure mode this file exists to catch.
  """
  use ExUnit.Case, async: true

  alias EdgeLinkouts.Codec
  alias EdgeLinkouts.Display
  alias EdgeLinkouts.Display.{Config, Segment, Value}

  @fixtures Path.expand("../fixtures/contract/docs.ndjson", __DIR__)
  @drift Path.expand("../fixtures/contract/drift.ndjson", __DIR__)
  @v1 "drug-approvals-kg-1.11.2"
  @v2 "drug-approvals-kg-1.16.0"

  setup_all do
    docs =
      @fixtures
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(&JSON.decode!/1)
      |> Enum.reject(&(&1["id"] == "__random_pool__"))

    resolved = resolve_all(@fixtures)

    legacy =
      for doc <- docs,
          {:ok, blob} = Codec.decode(doc["b"]),
          version <- Codec.versions(blob),
          {:ok, edge} = Codec.resolve(blob, version) do
        %{id: doc["id"], version: version, doc: edge}
      end

    _ = legacy
    {:ok, resolved: resolved, config: Display.get("drug-approvals-kg")}
  end

  # Every stored document in an NDJSON fixture, resolved at every version it holds.
  defp resolve_all(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      with %{"b" => b64} <- JSON.decode!(line),
           {:ok, blob} <- Codec.decode(b64) do
        for version <- Codec.versions(blob),
            {:ok, doc} = Codec.resolve(blob, version) do
          %{id: b64 && doc["id"], version: version, doc: doc}
        end
      else
        _ -> []
      end
    end)
  end

  describe "config loading" do
    test "the drug approvals KG has a config" do
      config = Display.get("drug-approvals-kg")
      assert config
      assert config.display_name == "Multiomics Drug Approvals"
      assert "drug-approvals-kg" in Display.known()
    end

    test "name_of splits a version key at the first numeric segment" do
      # Names contain hyphens, so splitting on the last one would give "drug-approvals-kg-1.16"
      # and on the first would give "drug".
      assert Display.name_of("drug-approvals-kg-1.16.0") == "drug-approvals-kg"
      assert Display.name_of("multiomics-kg-2.13.1") == "multiomics-kg"
      assert Display.name_of("no-version-here") == nil
      assert Display.for_key("drug-approvals-kg-1.16.0").name == "drug-approvals-kg"
    end

    test "every referenced name is a slot or a real field" do
      # A typo'd slot renders as a silently shorter sentence, which is indistinguishable from
      # missing data. mix linkouts.check cross-checks against the fixtures; assert it here too so
      # `mix test` alone catches it.
      config = Display.get("drug-approvals-kg")
      assert Display.unresolved_names(config) -- observed_fields() == []
    end
  end

  describe "the edge sentence" do
    test "a contraindication edge reads as a contraindication", %{
      resolved: resolved,
      config: config
    } do
      contraindicated =
        Enum.find(
          resolved,
          &(&1.doc["predicate"] == "biolink:contraindicated_in" and &1.version == @v1)
        )

      assert contraindicated, "no contraindication edge in the fixtures"

      text =
        config |> Display.edge(contraindicated.doc, contraindicated.version) |> Segment.to_text()

      # The legacy Perl matched /^biolink:contraindicated/ rather than listing predicates, so any
      # future contraindication predicate in the family renders correctly too.
      assert text =~ "is contraindicated for patients with"
      assert text =~ contraindicated.doc["subject_name"]
      assert text =~ contraindicated.doc["object_name"]
      assert String.starts_with?(text, "This relationship states that ")
      assert String.ends_with?(text, ".")
    end

    test "the subject and object become links to their identifiers", %{
      resolved: resolved,
      config: config
    } do
      edge = Enum.find(resolved, &(&1.version == @v1))
      segments = Display.edge(config, edge.doc, edge.version)

      links = for {:link, href, label} <- segments, do: {label, href}

      assert {edge.doc["subject_name"], href_for(edge.doc["subject"])} in links
      assert {edge.doc["object_name"], href_for(edge.doc["object"])} in links
    end

    test "no segment contains markup, so upstream data cannot inject HTML", %{
      resolved: resolved,
      config: config
    } do
      # The legacy code interpolated KG values straight into HTML strings. Segments are data and
      # the template escapes them; this asserts the display layer never produces markup itself.
      hostile = Map.put(hd(resolved).doc, "subject_name", "<script>alert(1)</script>")

      for segment <- Display.edge(config, hostile, @v1) do
        case segment do
          {:text, text} -> refute text =~ "<a href"
          {:link, href, _label} -> assert String.starts_with?(href, "https://")
        end
      end

      assert Segment.to_text(Display.edge(config, hostile, @v1)) =~ "<script>alert(1)</script>"
    end

    test "a missing node name still renders the identifier", %{resolved: resolved, config: config} do
      edge = Enum.find(resolved, &(&1.version == @v1))
      nameless = Map.delete(edge.doc, "subject_name")

      text = config |> Display.edge(nameless, @v1) |> Segment.to_text()

      # Falling back to the CURIE beats the legacy "[[missing name for X]]" and beats dropping the
      # subject entirely, which would make the sentence claim something about nothing.
      assert text =~ edge.doc["subject"]
      refute text =~ "missing name"
    end
  end

  describe "version-scoped aliases" do
    test "the approvals row renders under either spelling of the field" do
      # The rename is real but is not visible inside one blob: docs.ndjson holds 1.11.2 and 1.16.0
      # both spelled FDA_regulatory_approvals, while drift.ndjson holds 1.16.0 spelled
      # regulatory_approvals. So the alias is proven across two fixture files rather than two
      # versions of one edge — which is also how the drift actually reaches production: a new dump
      # arrives with the new spelling while stored documents keep the old one.
      config = Display.get("drug-approvals-kg")

      for {path, expected_key} <- [
            {@fixtures, "FDA_regulatory_approvals"},
            {@drift, "regulatory_approvals"}
          ] do
        seen =
          for %{version: version, doc: doc} <- resolve_all(path),
              Map.has_key?(doc, expected_key) do
            labels =
              config |> Display.evidence(doc, version) |> Enum.map(&Segment.to_text(&1.label))

            assert "Relevant approvals" in labels,
                   "#{Path.basename(path)} #{version} has #{expected_key} but rendered no approvals row"

            row =
              config
              |> Display.evidence(doc, version)
              |> Enum.find(&(Segment.to_text(&1.label) == "Relevant approvals"))

            assert row.value != [],
                   "#{Path.basename(path)} #{version} rendered an empty approvals row"

            version
          end

        assert seen != [], "no document in #{Path.basename(path)} carries #{expected_key}"
      end
    end

    test "a document with neither spelling renders no approvals row", %{
      resolved: resolved,
      config: config
    } do
      # The corollary: the alias must not make the row appear out of nothing, because an empty
      # "Relevant approvals" line reads as a claim that there are none.
      edge =
        Enum.find(resolved, fn %{doc: doc} ->
          not Map.has_key?(doc, "FDA_regulatory_approvals") and
            not Map.has_key?(doc, "regulatory_approvals")
        end)

      assert edge, "expected a fixture edge with no approvals field at all"

      labels =
        config |> Display.evidence(edge.doc, edge.version) |> Enum.map(&Segment.to_text(&1.label))

      refute "Relevant approvals" in labels
    end

    test "an unscoped alias applies at every version, canonical name first", %{config: config} do
      # The rename is not version-gated in the real data, so the alias must not be either. Order
      # matters: a document carrying both spellings resolves to the canonical one.
      for version <- [@v1, @v2] do
        assert Display.Config.aliases_for(config, version) == %{
                 "regulatory_approvals" => ["regulatory_approvals", "FDA_regulatory_approvals"]
               }
      end

      both = %{
        "regulatory_approvals" => ["new"],
        "FDA_regulatory_approvals" => ["old"]
      }

      assert config |> Display.context(both, @v1) |> Value.fetch("regulatory_approvals") == [
               "new"
             ]

      legacy = %{"FDA_regulatory_approvals" => ["old"]}

      assert config |> Display.context(legacy, @v1) |> Value.fetch("regulatory_approvals") == [
               "old"
             ]
    end

    test "a version-scoped alias only applies inside its range" do
      # Scoped aliases still work for KGs whose renames really are version boundaries, and are
      # tried before unscoped ones because they say more about that release.
      {:ok, config} =
        Config.new(%{
          name: "scoped-kg",
          display_name: "Scoped",
          edge: "{thing}",
          aliases: [
            %{field: "thing", as: "old_thing", versions: "<2.0.0"},
            %{field: "thing", as: "other_thing"}
          ]
        })

      assert Config.aliases_for(config, "scoped-kg-1.5.0") == %{
               "thing" => ["thing", "old_thing", "other_thing"]
             }

      assert Config.aliases_for(config, "scoped-kg-2.1.0") == %{
               "thing" => ["thing", "other_thing"]
             }
    end
  end

  describe "evidence" do
    test "rows with no data are omitted rather than rendered empty", %{
      resolved: resolved,
      config: config
    } do
      edge =
        Enum.find(resolved, &(&1.version == @v1 and not Map.has_key?(&1.doc, "number_of_cases")))

      assert edge, "expected a fixture edge without a FAERS case count"

      labels =
        config |> Display.evidence(edge.doc, edge.version) |> Enum.map(&Segment.to_text(&1.label))

      refute "Number of FAERS cases reporting this usage" in labels
      # The search row has no :if, so it is always present.
      assert "Search product labels" in labels
    end

    test "DailyMed publications become product-label links", %{resolved: resolved, config: config} do
      edge = Enum.find(resolved, &(&1.version == @v1 and is_list(&1.doc["publications"])))
      assert edge

      rows = Display.evidence(config, edge.doc, edge.version)
      row = Enum.find(rows, &(Segment.to_text(&1.label) == "Relevant product labels"))
      assert row

      hrefs = for {:link, href, _label} <- row.value, do: href

      for publication <- edge.doc["publications"] do
        "dailymed:" <> setid = publication
        assert "https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=#{setid}" in hrefs
      end
    end

    test "FDA application numbers link to the label browser", %{
      resolved: resolved,
      config: config
    } do
      edge =
        Enum.find(
          resolved,
          &(&1.version == @v1 and Map.has_key?(&1.doc, "FDA_regulatory_approvals"))
        )

      assert edge

      rows = Display.evidence(config, edge.doc, edge.version)
      row = Enum.find(rows, &(Segment.to_text(&1.label) == "Relevant approvals"))
      assert row

      hrefs = for {:link, href, _label} <- row.value, do: href
      assert hrefs != []
      assert Enum.all?(hrefs, &String.starts_with?(&1, "https://fda.report/applications/"))
    end

    test "the source-record row lists knowledge sources", %{resolved: resolved, config: config} do
      edge = Enum.find(resolved, &(&1.version == @v1))
      rows = Display.evidence(config, edge.doc, edge.version)
      row = Enum.find(rows, &(Segment.to_text(&1.label) == "Primary knowledge sources"))
      assert row
      assert Segment.to_text(row.value) =~ "infores:"
    end

    test "search links percent-encode the drug names they embed", %{
      resolved: resolved,
      config: config
    } do
      edge = Enum.find(resolved, &(&1.version == @v1))
      rows = Display.evidence(config, edge.doc, edge.version)
      row = Enum.find(rows, &(Segment.to_text(&1.label) == "Search product labels"))

      [_both | _] = links = for {:link, href, _} <- row.value, do: href
      assert length(links) == 2

      # A name with a space or an ampersand must not break the query or add a parameter.
      for href <- links do
        assert href =~ "dailymed.nlm.nih.gov/dailymed/search.cfm"
        refute href =~ " "
      end
    end
  end

  describe "version gates" do
    test "the disease-context clause is suppressed for 1.0.0 and earlier" do
      # The legacy code gated this on `$version gt '1.0.0'`; the gate is kept because earlier
      # releases did not populate the qualifier and would render "in the context of" with nothing
      # after it.
      config = Display.get("drug-approvals-kg")

      doc = %{
        "subject" => "CHEBI:1",
        "subject_name" => "aspirin",
        "object" => "MONDO:1",
        "object_name" => "fever",
        "predicate" => "biolink:treats",
        "disease_context_qualifier" => "MONDO:2",
        "disease_context_qualifier_name" => "adult fever"
      }

      modern = config |> Display.edge(doc, "drug-approvals-kg-1.11.2") |> Segment.to_text()
      old = config |> Display.edge(doc, "drug-approvals-kg-1.0.0") |> Segment.to_text()

      assert modern =~ "in the context of adult fever"
      refute old =~ "in the context of"
      assert old =~ "has been approved for treating"
    end

    test "object_modifier switches treating to preventing" do
      config = Display.get("drug-approvals-kg")

      base = %{
        "subject" => "CHEBI:1",
        "subject_name" => "aspirin",
        "object" => "MONDO:1",
        "object_name" => "fever",
        "predicate" => "biolink:treats"
      }

      plain = config |> Display.edge(base, @v1) |> Segment.to_text()

      prevention =
        config
        |> Display.edge(Map.put(base, "object_modifier", "prevention"), @v1)
        |> Segment.to_text()

      assert plain =~ "has been approved for treating fever"
      assert prevention =~ "has been approved for preventing fever"
    end
  end

  describe "segments" do
    test "adjacent text runs merge and nils drop" do
      assert Segment.join([Segment.text("a"), nil, Segment.text("b")]) == [{:text, "ab"}]
      assert Segment.join([]) == []
    end

    test "a non-http href degrades to text instead of becoming a link" do
      assert Segment.link("javascript:alert(1)", "click") == {:text, "click"}
      assert Segment.link("data:text/html,x", "click") == {:text, "click"}
      assert Segment.link(nil, "plain") == {:text, "plain"}
      assert Segment.link("https://x.test", "") == nil
    end

    test "to_text drops hrefs and keeps labels" do
      assert Segment.to_text([{:text, "see "}, {:link, "https://x.test", "this"}]) == "see this"
    end
  end

  # Field names present in the fixtures, used to prove a config references real data. Nested names
  # count too, because {:list, "sources", "{resource_id}", ", "} legitimately reaches into a KGX
  # sources entry.
  defp observed_fields do
    @fixtures
    |> stored_blobs()
    |> Enum.flat_map(&resolved_docs/1)
    |> Enum.flat_map(&field_names/1)
  end

  defp stored_blobs(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&JSON.decode!/1)
    |> Enum.flat_map(fn
      %{"b" => b64} ->
        case Codec.decode(b64) do
          {:ok, blob} -> [blob]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp resolved_docs(blob) do
    for version <- Codec.versions(blob),
        {:ok, doc} = Codec.resolve(blob, version),
        do: doc
  end

  defp field_names(doc) do
    nested =
      doc
      |> Map.values()
      |> Enum.filter(&is_list/1)
      |> List.flatten()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&Map.keys/1)

    Map.keys(doc) ++ nested
  end

  defp href_for("CHEBI:" <> _ = curie), do: "https://www.ebi.ac.uk/chebi/beta/#{curie}"
  defp href_for("MONDO:" <> id), do: "https://monarchinitiative.org/MONDO:#{id}"
end
