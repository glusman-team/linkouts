defmodule EdgeLinkoutsWeb.RandomControllerTest do
  use EdgeLinkoutsWeb.ConnCase, async: false

  alias EdgeLinkouts.Cosmos
  alias EdgeLinkoutsWeb.Fixtures

  @slug "drugapprovals-kp"
  @index_id "__random_pool__"
  # A second graph, so a scoped pick has something it must stay out of. Its ids are not stored
  # edge documents, which is the point: a redirect to one of them is a visible escape.
  @other_slug "other-kp"
  @other_id "aaaaaaaa-0000-4000-8000-000000000001"

  setup do
    Cosmos.Fake.reset()
    :ok
  end

  # The fixture store plus one invented graph, with an index that lists both.
  defp seed_two_kgs do
    Cosmos.Fake.seed(Fixtures.docs())
    Cosmos.Fake.seed_pool([@other_id], @other_slug, "0.1.0")

    Cosmos.Fake.seed_pool_index(%{
      @slug => %{"1.11.2" => 6, "1.16.0" => 6},
      @other_slug => %{"0.1.0" => 1}
    })
  end

  defp location(conn) do
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    location
  end

  # Not every seeded id is a UUID: the weighting tests use readable ones, and a redirect that
  # points anywhere else is the failure those tests are looking for.
  defp edge_id_from(location) do
    case Regex.run(~r|^/edges/([^?]+)|, location) do
      [_, id] -> id
      _ -> flunk("not a redirect to an edge: #{location}")
    end
  end

  describe "/random" do
    test "responds 302 with a location matching /edges/<uuid>", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      location = conn |> get(~p"/random") |> location()

      assert Regex.match?(~r|^/edges/[0-9a-f-]{36}\?version=|, location)
      assert edge_id_from(location) in all_fixture_edge_ids()
    end

    test "the redirect carries the release the id was sampled from", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      location = conn |> get(~p"/random") |> location()
      id = edge_id_from(location)

      # Opening the sampled release rather than the blob's newest is what makes the page agree
      # with the pick: a reader who asks for a random 1.11.2 edge must not land on 1.16.0.
      assert location == ~p"/edges/#{id}?version=#{Fixtures.v1()}" or
               location == ~p"/edges/#{id}?version=#{Fixtures.v2()}"
    end

    test "renders an empty-state page when there is no index, rather than looping to /", %{
      conn: conn
    } do
      # "/" is the KG bar, which links here, so redirecting back to "/" would loop. The honest
      # answer is a page that says nothing is stored yet.
      conn = get(conn, ~p"/random")

      assert html_response(conn, 404) =~ "Nothing to show yet"
    end

    test "answers 503 when the index read itself fails", %{conn: conn} do
      Cosmos.Fake.queue_error({:request_failed, 500})

      conn = get(conn, ~p"/random")

      assert html_response(conn, 503) =~ "did not answer"
    end

    test "answers 429 when the read budget is spent", %{conn: conn} do
      Cosmos.Fake.queue_error(:budget_exhausted)

      conn = get(conn, ~p"/random")

      assert html_response(conn, 429) =~ "read budget"
    end

    test "reads the index and exactly one pool per request", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      get(conn, ~p"/random")

      # Two point reads: the index says which releases exist and how big they are, then only
      # the chosen release's ids are fetched. Nothing queries the container.
      assert [{:get_edge, @index_id}, {:get_edge, pool_id}] = Cosmos.Fake.calls()
      assert Cosmos.reserved_id?(pool_id)
      assert String.starts_with?(pool_id, "__random_pool__:#{@slug}:")
    end

    test "a release whose pool is missing is skipped, not a dead end" do
      # One index entry with no pool document behind it: what a cached index looks like after
      # `linkouts purge --key`, and what a half-finished load looks like.
      Cosmos.Fake.seed(Fixtures.docs())

      Cosmos.Fake.seed_pool_index(%{
        @slug => %{"1.16.0" => 6},
        "gone-kp" => %{"9.9.9" => 5000}
      })

      Cosmos.Fake.seed(%{"id" => Cosmos.pool_doc_id("gone-kp", "9.9.9"), "b" => "not-a-frame"})

      for _ <- 1..20 do
        location = build_conn() |> get(~p"/random") |> location()
        assert edge_id_from(location) in Fixtures.pool_ids("1.16.0")
      end
    end
  end

  describe "/:kg/random" do
    test "stays inside the named graph" do
      seed_two_kgs()
      allowed = Fixtures.pool_ids("1.11.2") ++ Fixtures.pool_ids("1.16.0")

      for _ <- 1..25 do
        id = build_conn() |> get(~p"/#{@slug}/random") |> location() |> edge_id_from()
        assert id in allowed, "#{id} is not an edge of #{@slug}"
        refute id == @other_id
      end
    end

    test "the infores form of the name works too", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      # A curator copying the canonical identifier into a URL should not get a 404 for it.
      location = conn |> get("/infores:#{@slug}/random") |> location()

      assert edge_id_from(location) in all_fixture_edge_ids()
    end

    test "an unknown graph is a 404 that names it", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      conn = get(conn, ~p"/nosuchkg/random")

      html = html_response(conn, 404)
      assert html =~ "No random edge in"
      assert html =~ "infores:nosuchkg"
    end

    test "a graph listed with no releases is a 404", %{conn: conn} do
      Cosmos.Fake.seed_pool_index(%{@slug => %{}})

      assert html_response(get(conn, ~p"/#{@slug}/random"), 404) =~ "No random edge in"
    end
  end

  describe "/:kg/random?version=" do
    test "picks only from that release and opens that release" do
      Cosmos.Fake.seed(Fixtures.docs())
      ids = Fixtures.pool_ids("1.11.2")

      for _ <- 1..10 do
        location = build_conn() |> get(~p"/#{@slug}/random?version=1.11.2") |> location()
        assert edge_id_from(location) in ids
        # The exact key the CLI loaded the release under, taken from the pool document.
        assert location =~ "?version=" <> URI.encode_www_form(Fixtures.v1())
      end
    end

    test "a whole version key is accepted in place of a bare label", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      location = conn |> get(~p"/#{@slug}/random?version=#{Fixtures.v2()}") |> location()

      assert edge_id_from(location) in Fixtures.pool_ids("1.16.0")
    end

    test "an unknown release is a 404 that names it", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      conn = get(conn, ~p"/#{@slug}/random?version=9.9.9")

      html = html_response(conn, 404)
      assert html =~ "Drug Approvals KP"
      assert html =~ "9.9.9"
    end

    test "reads only that release's pool: no index read at all", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      get(conn, ~p"/#{@slug}/random?version=1.16.0")

      assert Cosmos.Fake.calls() == [{:get_edge, Cosmos.pool_doc_id(@slug, "1.16.0")}]
    end
  end

  describe "weighting" do
    test "a release with more edges is picked proportionally more often" do
      # Uniform over the store, not uniform over releases: 1000:1 means the small release
      # should be drawn about once in a thousand, so seeing it more than a handful of times
      # in 100 draws means the weighting is not being applied.
      Cosmos.Fake.seed_pool(["big-1"], "big-kp", "1.0.0")
      Cosmos.Fake.seed_pool(["small-1"], "small-kp", "1.0.0")

      Cosmos.Fake.seed_pool_index(%{
        "big-kp" => %{"1.0.0" => 1000},
        "small-kp" => %{"1.0.0" => 1}
      })

      draws =
        for _ <- 1..100 do
          build_conn() |> get(~p"/random") |> location() |> edge_id_from()
        end

      assert Enum.count(draws, &(&1 == "big-1")) >= 90
    end

    test "an index whose releases all report zero edges still picks", %{conn: conn} do
      # Refusing to choose would 404 a store that does hold pools; a count of zero means the
      # loader did not know the size, not that the release is empty.
      Cosmos.Fake.seed_pool(["zero-1"], "zero-kp", "1.0.0")
      Cosmos.Fake.seed_pool_index(%{"zero-kp" => %{"1.0.0" => 0}})

      assert conn |> get(~p"/random") |> location() |> edge_id_from() == "zero-1"
    end
  end

  defp all_fixture_edge_ids do
    Fixtures.docs()
    |> Enum.reject(&Cosmos.reserved_id?(&1["id"]))
    |> Enum.map(& &1["id"])
  end
end
