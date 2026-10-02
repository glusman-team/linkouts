defmodule EdgeLinkoutsWeb.EdgeLiveTest do
  use EdgeLinkoutsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EdgeLinkouts.Codec
  alias EdgeLinkouts.{Cosmos, Dedupe}
  alias EdgeLinkoutsWeb.Fixtures

  @v1 Fixtures.v1()
  @v2 Fixtures.v2()

  # The global Fake (started by the supervision tree in test) is a singleton, so every
  # test here is serial; each one reseeds it from the committed contract fixtures.
  setup do
    Cosmos.Fake.reset()
    Cosmos.Fake.seed(Fixtures.docs())

    %{id: Fixtures.first_edge_id()}
  end

  describe "the linkout page" do
    test "renders the sentence, diagram labels and evidence rows at both stored versions", %{
      id: id
    } do
      for version <- [@v1, @v2] do
        doc = Fixtures.resolved(Fixtures.edge_doc(id), version)
        {:ok, _view, html} = live(build_conn(), "/edges/#{id}?version=#{version}")

        assert html =~ "This relationship states that"
        assert html =~ doc["subject_name"]
        assert html =~ doc["object_name"]

        # The SVG diagram shows both node names and their CURIEs.
        assert html =~ "edge-diagram"
        assert html =~ doc["subject"]
        assert html =~ doc["object"]
        assert html =~ doc["predicate"]

        # The evidence panel carries at least the always-present search row.
        assert html =~ "Evidence"
        assert html =~ "Search product labels"
      end
    end

    test "a full page view, static render plus connected mount, costs one backend read", %{
      conn: conn,
      id: id
    } do
      # The test env runs the shared Dedupe with its result cache off, so tests cannot leak
      # documents into each other. Turn it on here to check what production does. Without the
      # cache this was two reads per page view, because the two mounts are sequential and
      # coalescing alone cannot merge them.
      # The cleanup must clear the table as well as restore the ttl. Restoring the ttl alone leaves
      # this test's cached document behind, and the next test reads it instead of the Fake.
      # Seed 92193 caught that. The ExUnit case is async: false, so nothing else runs meanwhile.
      Dedupe.clear()
      :sys.replace_state(Dedupe, &%{&1 | ttl_ms: 30_000})

      on_exit(fn ->
        :sys.replace_state(Dedupe, &%{&1 | ttl_ms: 0})
        Dedupe.clear()
      end)

      {:ok, _view, _html} = live(conn, "/edges/#{id}")

      assert Cosmos.Fake.calls() == [{:get_edge, id}]
    end

    test "switching ?version selects that version without a second backend read", %{
      conn: conn,
      id: id
    } do
      {:ok, view, html} = live(conn, "/edges/#{id}")

      # live/2 mounts twice (static render, then connected). With the result cache off, as it
      # is in tests, that is two reads; the test above covers the production count. The
      # invariant here is that switching the version adds nothing, because the blob in the
      # assigns already holds every stored version.
      calls_after_load = Cosmos.Fake.calls()
      assert calls_after_load != []
      assert Enum.all?(calls_after_load, &match?({:get_edge, ^id}, &1))

      # The switcher links to every stored version.
      assert html =~ "?version=#{@v1}"
      assert html =~ "?version=#{@v2}"

      # Patching is exactly what a switcher link does.
      render_patch(view, "/edges/#{id}?version=#{@v1}")

      assert Cosmos.Fake.calls() == calls_after_load
      assert render(view) =~ "aria-current=\"page\""
      assert render(view) =~ "<strong>#{@v1}</strong>"
    end

    test "an unknown id answers HTTP 404 with the not-found copy", %{conn: conn} do
      # The LiveView raises EdgeNotFound (plug_status 404); the endpoint renders the 404
      # page with that status and then re-raises, which is Phoenix's behaviour for every
      # rendered error. The response body is asserted end to end via the download
      # controller (same 404 page) and the curl check in the verification run.
      raised =
        assert_raise EdgeLinkoutsWeb.EdgeNotFound, fn ->
          get(conn, "/edges/00000000-0000-0000-0000-000000000000")
        end

      assert raised.plug_status == 404
      assert raised.message =~ "no edge with id"
    end

    # Both ways the transport refuses for capacity: the local RU budget (checked before the call)
    # and Cosmos's own 429 after the single retry. Each must read as "retry", not as a store outage,
    # which is what the page said before Edges.read/2 mapped them.
    for {label, reason} <- [
          {"the local RU budget", :budget_exhausted},
          {"Cosmos 429 after the retry", {:throttled, 250}}
        ] do
      test "#{label} renders the retry copy, not an error term", %{conn: conn, id: id} do
        # live/2 mounts twice (static render, then the connected process), so queue the
        # refusal for both reads.
        Cosmos.Fake.queue_error(unquote(Macro.escape(reason)))
        Cosmos.Fake.queue_error(unquote(Macro.escape(reason)))

        {:ok, view, html} = live(conn, "/edges/#{id}")

        assert html =~ "Rate limited"
        assert html =~ "Retry"
        refute html =~ "could not be reached"
        refute html =~ "{:error"
        refute html =~ "budget_exhausted"
        refute html =~ "throttled"

        # Once reads are admitted again, the retry event loads the page in place.
        render_click(view, "retry", %{})
        assert render(view) =~ "This relationship states that"
      end
    end

    test "a store outage says so, distinct from rate limiting", %{conn: conn, id: id} do
      Cosmos.Fake.queue_error({:http, 503, "unavailable"})
      Cosmos.Fake.queue_error({:http, 503, "unavailable"})

      {:ok, _view, html} = live(conn, "/edges/#{id}")

      assert html =~ "could not be reached"
      refute html =~ "Rate limited"
      refute html =~ "503"
    end

    test "a corrupt blob names the reason instead of a generic failure", %{conn: conn} do
      Cosmos.Fake.seed(%{"id" => "corrupt-edge", "b" => "!!! not base64 !!!"})

      {:ok, _view, html} = live(conn, "/edges/corrupt-edge")

      assert html =~ "Corrupt stored document"
      assert html =~ "not valid base64"
      refute html =~ "{:error"
    end

    test "an unknown ?version names it in the corrupt copy", %{conn: conn, id: id} do
      {:ok, _view, html} = live(conn, "/edges/#{id}?version=nope-9.9.9")

      assert html =~ "Corrupt stored document"
      assert html =~ "does not store a version"
      assert html =~ "nope-9.9.9"
    end

    test "a hostile subject_name appears escaped and never as a live tag", %{conn: conn} do
      id = "22222222-2222-4222-8222-222222222222"
      base = Fixtures.resolved(Fixtures.edge_doc(Fixtures.first_edge_id()), @v1)
      hostile = Map.put(base, "subject_name", "<script>alert(1)</script>")

      Cosmos.Fake.seed(Fixtures.stored(id, %{@v1 => hostile}))

      {:ok, _view, html} = live(conn, "/edges/#{id}")

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)</script>"
    end
  end

  describe "the version diff" do
    test "shows an added field, a removed field and a changed value", %{conn: conn} do
      id = "33333333-3333-4333-8333-333333333333"

      v1 = %{
        "id" => id,
        "subject" => "CHEBI:64019",
        "subject_name" => "aspirin",
        "object" => "MONDO:0000418",
        "object_name" => "ischemic stroke",
        "predicate" => "biolink:treats",
        "number_of_cases" => 12,
        "knowledge_level" => "assertion",
        "publications" => ["PMID:1"]
      }

      v2 = %{
        "$t" => @v1,
        "$set" => %{"number_of_cases" => 42},
        "$add" => %{"publications" => ["PMID:2"]},
        "$del" => ["knowledge_level"]
      }

      Cosmos.Fake.seed(Fixtures.stored(id, %{@v1 => v1, @v2 => v2}))

      {:ok, _view, html} = live(conn, "/edges/#{id}")

      assert html =~ "Changes from"
      assert html =~ "diff-line-added"
      assert html =~ "diff-line-removed"

      # Changed value: old -> new, both visible.
      assert html =~ "<code>12</code>"
      assert html =~ "<code>42</code>"
      assert html =~ "-&gt;"

      # Added list element and removed field, each with their own marker.
      assert html =~ "&quot;PMID:2&quot;"
      assert html =~ "knowledge_level"
      assert html =~ "&quot;assertion&quot;"
    end

    test "a single-version page says there is nothing earlier to compare", %{conn: conn} do
      id = "44444444-4444-4444-8444-444444444444"

      v1 = %{
        "id" => id,
        "subject" => "CHEBI:64019",
        "subject_name" => "aspirin",
        "object" => "MONDO:0000418",
        "object_name" => "ischemic stroke",
        "predicate" => "biolink:treats"
      }

      Cosmos.Fake.seed(Fixtures.stored(id, %{@v1 => v1}))

      {:ok, _view, html} = live(conn, "/edges/#{id}")

      assert html =~ "nothing earlier to compare"
    end
  end

  describe "the KGX download link" do
    test "the feedback link carries the current permalink", %{conn: conn, id: id} do
      {:ok, _view, html} = live(conn, "/edges/#{id}")

      # The test conn's host is www.example.com.
      permalink = "http://www.example.com/edges/#{id}"
      assert html =~ URI.encode_www_form(permalink)
    end
  end

  # The downloaded bytes must be identical to what Codec would canonicalise, so this
  # helper is shared with the controller test.
  def canonical_at(id, key),
    do: Fixtures.edge_doc(id) |> Fixtures.resolved(key) |> Codec.canonical_binary()
end
