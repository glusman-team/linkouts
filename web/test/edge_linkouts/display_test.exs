defmodule EdgeLinkouts.DisplayTest do
  @moduledoc """
  Renders real stored documents through the drug approvals config.

  These assertions use the committed contract fixtures rather than invented maps, so they check
  the config against field names that actually occur in DAKP data. A config that validates but
  renders nothing is the failure mode this file exists to catch.
  """
  use ExUnit.Case, async: true

  alias EdgeLinkouts.{Codec, Cosmos}
  alias EdgeLinkouts.Display
  alias EdgeLinkouts.Display.{Config, Segment, Value}

  @fixtures Path.expand("../fixtures/contract/docs.ndjson", __DIR__)
  @drift Path.expand("../fixtures/contract/drift.ndjson", __DIR__)
  @v1 "infores:drugapprovals-kp-1.11.2"
  @v2 "infores:drugapprovals-kp-1.16.0"

  setup_all do
    docs =
      @fixtures
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(&JSON.decode!/1)
      # The fixture file also holds the reserved pool documents behind /random; they are not
      # edge blobs and must not be decoded as ones.
      |> Enum.reject(&Cosmos.reserved_id?(&1["id"]))

    resolved = resolve_all(@fixtures)

    legacy =
      for doc <- docs,
          {:ok, blob} = Codec.decode(doc["b"]),
          version <- Codec.versions(blob),
          {:ok, edge} = Codec.resolve(blob, version) do
        %{id: doc["id"], version: version, doc: edge}
      end

    _ = legacy
    {:ok, resolved: resolved, config: Display.get("infores:drugapprovals-kp")}
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
      config = Display.get("infores:drugapprovals-kp")
      assert config
      assert config.display_name == "DrugApprovals KP"
      assert "infores:drugapprovals-kp" in Display.known()
    end

    test "name_of splits a version key at the first numeric segment" do
      # Names contain hyphens, so splitting on the last one would give "infores:drugapprovals-kp-1.16"
      # and on the first would give "infores:drugapprovals". The colon in a canonical name is
      # just another character here: the split is at the hyphen before the numeric segment.
      assert Display.name_of("infores:drugapprovals-kp-1.16.0") == "infores:drugapprovals-kp"
      assert Display.name_of("multiomics-kg-2.13.1") == "multiomics-kg"
      assert Display.name_of("no-version-here") == nil
      assert Display.for_key("infores:drugapprovals-kp-1.16.0").name == "infores:drugapprovals-kp"
    end

    test "a version key stored without the infores prefix gets the same config" do
      # The live store was loaded as "drugapprovals-kp-1.23.4"; an exact-name lookup fell back
      # to the generic default and the edge page lost its sentence, evidence, about section and
      # known-issue notice.
      for key <- ["drugapprovals-kp-1.23.4", "infores:drugapprovals-kp-1.23.4"] do
        config = Display.for_key(key)
        assert config.name == "infores:drugapprovals-kp", key
        assert config.display_name == "DrugApprovals KP"
      end

      assert Display.get("drugapprovals-kp") == Display.get("infores:drugapprovals-kp")

      assert Display.known_error(
               Display.for_key("drugapprovals-kp-1.23.3"),
               "drugapprovals-kp-1.23.3"
             )

      assert Display.get("no-such-kp") == nil
      assert Display.for_key("no-such-kp-1.0.0").name == "default"
    end

    test "a slug is the name without its infores prefix, and expands back to it" do
      # The slug is what a document stores and what a URL carries; the canonical name is what
      # the config table is keyed by. Both directions have to agree or a link on the bar points
      # at a graph the display layer cannot find.
      assert Display.slug("infores:drugapprovals-kp") == "drugapprovals-kp"
      assert Display.slug("drugapprovals-kp") == "drugapprovals-kp"
      assert Display.slug(nil) == nil

      assert Display.kg_from_slug("drugapprovals-kp") == "infores:drugapprovals-kp"
      # Accepting the full form too means a URL that carries it is not a 404.
      assert Display.kg_from_slug("infores:drugapprovals-kp") == "infores:drugapprovals-kp"
      assert Display.kg_from_slug(nil) == nil
    end

    test "a slug with no config expands to the infores form, and keeps a foreign scheme" do
      # A stored graph with no display config still renders (the generic view), so its name has
      # to be derivable from the slug alone.
      assert Display.kg_from_slug("some-future-kp") == "infores:some-future-kp"
      # A name that already carries a scheme is not infores-registered; prefixing it would
      # invent an identifier.
      assert Display.kg_from_slug("other:thing") == "other:thing"
      assert Display.slug("other:thing") == "other:thing"
    end

    test "every referenced name is a slot or a real field" do
      # A typo'd slot renders as a silently shorter sentence, which is indistinguishable from
      # missing data. mix linkouts.check cross-checks against the fixtures; assert it here too so
      # `mix test` alone catches it.
      config = Display.get("infores:drugapprovals-kp")
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
      config = Display.get("infores:drugapprovals-kp")

      for {path, expected_key} <- [
            {@fixtures, "FDA_regulatory_approvals"},
            {@drift, "regulatory_approvals"}
          ] do
        seen =
          for %{version: version, doc: doc} <- resolve_all(path),
              Map.has_key?(doc, expected_key) do
            evidence = config |> Display.evidence(doc, version) |> Segment.flatten()
            hrefs = for {:link, href, _label} <- evidence, do: href

            assert Segment.to_text(evidence) =~ "documented under",
                   "#{Path.basename(path)} #{version} has #{expected_key} but rendered no approvals sentence"

            assert Enum.any?(hrefs, &String.starts_with?(&1, "https://fda.report/applications/")),
                   "#{Path.basename(path)} #{version} rendered no FDA application link"

            version
          end

        assert seen != [], "no document in #{Path.basename(path)} carries #{expected_key}"
      end
    end

    test "a document with neither spelling renders no approvals sentence", %{
      resolved: resolved,
      config: config
    } do
      # The corollary: the alias must not make the sentence appear out of nothing, because
      # a approvals sentence with nothing behind it reads as a claim that there is a label.
      edge =
        Enum.find(resolved, fn %{doc: doc} ->
          not Map.has_key?(doc, "FDA_regulatory_approvals") and
            not Map.has_key?(doc, "regulatory_approvals")
        end)

      assert edge, "expected a fixture edge with no approvals field at all"

      refute config |> Display.evidence(edge.doc, edge.version) |> Segment.to_text() =~
               "documented under"
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
    test "sentences with no data are omitted rather than rendered empty", %{
      resolved: resolved,
      config: config
    } do
      edge =
        Enum.find(resolved, &(&1.version == @v1 and not Map.has_key?(&1.doc, "number_of_cases")))

      assert edge, "expected a fixture edge without a FAERS case count"

      text = config |> Display.evidence(edge.doc, edge.version) |> Segment.to_text()

      # "holds  cases reporting this usage" with a hole in it would misstate the source.
      refute text =~ "FAERS"
      # The search sentence moved to the footnote paragraph, so the evidence paragraph no
      # longer carries it.
      refute text =~ "Try searching DailyMed"

      footnote = config |> Display.footnote(edge.doc, edge.version) |> Segment.to_text()
      assert footnote =~ "Try searching DailyMed"
    end

    test "the paragraph is prose: no storage key with underscores leaks into it", %{
      resolved: resolved,
      config: config
    } do
      # Values like agent_type are humanized into words before they reach the paragraph; a
      # reader should never meet "manual_validation_of_automated_agent" in a sentence.
      for %{version: version, doc: doc} <- resolved, version == @v1 do
        refute config |> Display.evidence(doc, version) |> Segment.to_text() =~ "_"
      end
    end

    test "DailyMed publications become product-label links", %{resolved: resolved, config: config} do
      edge = Enum.find(resolved, &(&1.version == @v1 and is_list(&1.doc["publications"])))
      assert edge

      evidence = Display.evidence(config, edge.doc, edge.version) |> Segment.flatten()
      assert Segment.to_text(evidence) =~ "documented on the product labels"

      links = for {:link, href, label} <- evidence, do: {label, href}

      for publication <- edge.doc["publications"] do
        "dailymed:" <> setid = publication

        # The exact set id, shown and linked, not a labelled "1" the reader must count.
        assert {setid, "https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=#{setid}"} in links
      end
    end

    test "an edge with no approvals or product labels says so instead of going quiet", %{
      resolved: resolved,
      config: config
    } do
      # The legacy page printed its product-labels line even when empty ("None."); a reader must
      # never wonder whether facts were dropped by the renderer.
      edge =
        Enum.find(resolved, fn %{doc: doc} ->
          not Map.has_key?(doc, "FDA_regulatory_approvals") and
            not Map.has_key?(doc, "regulatory_approvals") and
            not Map.has_key?(doc, "publications")
        end)

      assert edge, "expected a fixture edge with neither approvals nor product labels"

      text = config |> Display.evidence(edge.doc, edge.version) |> Segment.to_text()
      assert text =~ "No FDA application numbers are recorded for this association."

      assert text =~
               "No structured-product-label set identifiers are recorded for this association."
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

      evidence = Display.evidence(config, edge.doc, edge.version) |> Segment.flatten()
      assert Segment.to_text(evidence) =~ "documented under"

      hrefs =
        for {:link, href, _label} <- evidence,
            String.starts_with?(href, "https://fda.report/applications/") do
          href
        end

      assert hrefs != []
    end

    test "the relationship names the integrator, then its supporting sources", %{
      resolved: resolved,
      config: config
    } do
      edge = Enum.find(resolved, &(&1.version == @v1))

      text = config |> Display.relationship(edge.doc, edge.version) |> Segment.to_text()

      # The primary source is the generator, so the closing sentence names it with its old
      # emphasis and registry link, then lists only the supporting sources (the primary
      # renders empty and the list drops it). Each source is named in words from the RIG's
      # supporting_data_source_info; a single supporting source takes no conjunction.
      assert text =~
               "This association was generated by DrugApprovals KP, which integrates DailyMed."

      refute text =~ "(primary)"
      refute text =~ "(supporting)"

      # The generator carries its old emphasis and linkout: bold, linking to its registry page.
      assert [{:strong, strong_inner}] =
               Enum.filter(
                 Display.relationship(config, edge.doc, edge.version),
                 &match?({:strong, _}, &1)
               )

      assert [{:link, href, "DrugApprovals KP"}] = strong_inner

      assert href ==
               "https://biolink.github.io/information-resource-registry/resources/drugapprovals-kp/"
    end

    test "search links percent-encode the drug names they embed", %{
      resolved: resolved,
      config: config
    } do
      edge = Enum.find(resolved, &(&1.version == @v1))
      footnote = Display.footnote(config, edge.doc, edge.version) |> Segment.flatten()

      links =
        for {:link, href, _} <- footnote,
            href =~ "dailymed.nlm.nih.gov/dailymed/search.cfm" do
          href
        end

      assert length(links) == 3

      # A name with a space or an ampersand must not break the query or add a parameter.
      for href <- links do
        refute href =~ " "
      end
    end

    test "search queries OR the preferred name with each pipe-delimited original", %{
      resolved: resolved,
      config: config
    } do
      edge = Enum.find(resolved, &(&1.version == @v1))

      doc =
        Map.merge(edge.doc, %{
          "subject_name" => "desflurane",
          "original_subject" => "DESFLURANE|Desflurane USAN",
          "object_name" => "asthma",
          "original_object" => "asthma|Asthma (disorder)|ASTHMA"
        })

      footnote = Display.footnote(config, doc, edge.version) |> Segment.flatten()

      links =
        for {:link, href, _} <- footnote,
            href =~ "dailymed.nlm.nih.gov/dailymed/search.cfm" do
          href
        end

      assert [subject_href, object_href, both_href] = links

      # Every name the source used is a quoted phrase in one OR group; case-insensitive
      # duplicates collapse to the first spelling. The link text keeps the preferred name,
      # so only the underlying query changes.
      assert subject_href =~
               "query=%22desflurane%22+OR+%22Desflurane+USAN%22"

      assert object_href =~
               "query=%22asthma%22+OR+%22Asthma+%28disorder%29%22"

      assert both_href =~
               "query=(%22desflurane%22+OR+%22Desflurane+USAN%22)+AND+34067-9:(%22asthma%22+OR+%22Asthma+%28disorder%29%22)"
    end
  end

  describe "version gates" do
    test "known_error matches by release and by full key, and misses untouched releases" do
      # The shipped config declares one issue (1.23.3's missing db.systemsbiology.net per-edge
      # linkouts); the matching logic is also exercised on a hand-built multi-version issue so
      # range requirements stay covered.
      # A pattern match both asserts the config exists and refines the type, so the struct
      # update below cannot warn about updating a possibly-nil value.
      assert %Display.Config{} = config = Display.get("infores:drugapprovals-kp")

      assert %{} = error = Display.known_error(config, "1.23.3")
      assert error.description =~ "db.systemsbiology.net"

      assert %{} = Display.known_error(config, "infores:drugapprovals-kp-1.23.3")
      assert Display.known_error(config, "1.16.0") == nil
      assert Display.known_error(config, "1.11.2") == nil
      assert Display.known_error(nil, "1.23.3") == nil

      flagged = %Display.Config{
        config
        | known_errors: [
            %{
              description:
                "Some applied-to-treat edges in this release incorrectly display regulatory approvals.",
              versions: ["1.11.2", "1.16.0"]
            }
          ]
      }

      assert %{} = error = Display.known_error(flagged, "1.16.0")
      assert error.description =~ "applied-to-treat edges"

      assert %{} = Display.known_error(flagged, "infores:drugapprovals-kp-1.11.2")
      assert Display.known_error(flagged, "1.17.0") == nil
      assert Display.known_error(flagged, "2.0.0") == nil
    end

    test "the disease-context clause renders whenever a displayable name exists" do
      # The gate is on the name field, not the version: a CURIE without a name would print
      # " in the context of " with nothing after it, so it is suppressed instead; a name at
      # any release renders.
      config = Display.get("infores:drugapprovals-kp")

      base = %{
        "subject" => "CHEBI:1",
        "subject_name" => "aspirin",
        "object" => "MONDO:1",
        "object_name" => "fever",
        "predicate" => "biolink:treats",
        "disease_context_qualifier" => "MONDO:2"
      }

      with_name =
        config
        |> Display.edge(
          Map.put(base, "disease_context_qualifier_name", "adult fever"),
          "infores:drugapprovals-kp-1.0.0"
        )
        |> Segment.to_text()

      without_name = config |> Display.edge(base, @v1) |> Segment.to_text()

      assert with_name =~ "in the context of adult fever"
      refute without_name =~ "in the context of"
    end

    test "for_key falls back to the default config, and named configs still win" do
      assert Display.for_key("infores:some-other-kp-1.0.0").name == "default"
      assert Display.for_key("infores:drugapprovals-kp-1.23.3").name == "infores:drugapprovals-kp"
      assert Display.default().name == "default"
      # The default is infrastructure: it is not a KG name a curator could configure.
      refute "default" in Display.known()
    end

    test "the default config renders a bare KGX document" do
      config = Display.default()

      plain =
        config
        |> Display.relationship(
          %{"subject" => "X:1", "predicate" => "biolink:treats", "object" => "Y:2"},
          "infores:some-other-kp-1.0.0"
        )
        |> Segment.to_text()

      # No names, no categories, no provenance: every absent field drops its clause.
      assert plain =~ "X:1 treats Y:2."
      refute plain =~ "a "

      named =
        config
        |> Display.relationship(
          %{
            "subject" => "CHEBI:1",
            "subject_name" => "aspirin",
            "subject_category" => ["biolink:SmallMolecule"],
            "predicate" => "biolink:treats",
            "object" => "MONDO:1",
            "object_name" => "fever",
            "object_category" => ["biolink:Disease"],
            "knowledge_level" => "knowledge_assertion",
            "agent_type" => "automated_agent",
            "sources" => [
              %{
                "resource_id" => "infores:some-other-kp",
                "resource_role" => "primary_knowledge_source"
              }
            ]
          },
          "infores:some-other-kp-1.0.0"
        )
        |> Segment.to_text()

      assert named =~
               "aspirin, a SmallMolecule, treats fever, a Disease. This assertion is machine-generated."
    end

    test "the default config renders the sources sentence for a standard KGX provenance shape" do
      config = Display.default()

      doc = %{
        "subject" => "X:1",
        "predicate" => "biolink:treats",
        "object" => "Y:2",
        "sources" => [
          %{"resource_id" => "infores:some-kp", "resource_role" => "primary_knowledge_source"},
          %{"resource_id" => "infores:pubmed", "resource_role" => "supporting_data_source"}
        ]
      }

      text = config |> Display.evidence(doc, "infores:some-kp-1.0.0") |> Segment.to_text()

      assert text =~ "This association is derived from"
    end

    test "the qualifier stack reads the original supporting-text phrases" do
      # DAKP logs each qualifier's readable source phrase into supporting_text as
      # "original_{qualifier}: value"; the claim prefers those over the CURIEs, at every
      # release — the gates are on the qualifiers' presence, not the version.
      config = Display.get("infores:drugapprovals-kp")

      doc = %{
        "subject" => "CHEBI:1",
        "subject_name" => "aspirin",
        "object" => "MONDO:1",
        "object_name" => "fever",
        "predicate" => "biolink:treats",
        "anatomical_context_qualifier" => "UBERON:1",
        "frequency_qualifier" => "UMLS:2",
        "population_context_qualifier" => "UMLS:3",
        "sex_qualifier" => "UMLS:C16573",
        "temporal_context_qualifier" => "UMLS:4",
        "supporting_text" => [
          "original_anatomical_context_qualifier: breast",
          "original_frequency_qualifier: dosage",
          "original_population_context_qualifier: pediatric patients",
          "original_sex_qualifier: adult|females",
          "original_temporal_context_qualifier: extended period of time"
        ]
      }

      rendered = config |> Display.edge(doc, @v1) |> Segment.to_text()
      old = config |> Display.edge(doc, "infores:drugapprovals-kp-1.0.0") |> Segment.to_text()

      # The frames read as one flowing clause, with rewordings repairing source fragments
      # (a lone "dosage", a singular "adult", a missing article).
      assert rendered =~
               ", in the breast, dosed at the labeled dosage, in pediatric patients, in adults, over an extended period of time."

      assert old == rendered

      # Pipe-separated alternates keep the first, canonical read.
      refute rendered =~ "females"
      refute rendered =~ "C16573"
    end

    test "a qualifier without a supporting-text phrase falls back to the labelled CURIE" do
      config = Display.get("infores:drugapprovals-kp")

      doc = %{
        "subject" => "CHEBI:1",
        "subject_name" => "aspirin",
        "object" => "MONDO:1",
        "object_name" => "fever",
        "predicate" => "biolink:treats",
        "sex_qualifier" => "UMLS:C16573"
      }

      text = config |> Display.edge(doc, @v1) |> Segment.to_text()

      assert text =~ ", sex UMLS:C16573"
    end

    test "object_modifier switches treating to preventing" do
      config = Display.get("infores:drugapprovals-kp")

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
