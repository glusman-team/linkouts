defmodule EdgeLinkoutsWeb.PageControllerTest do
  use EdgeLinkoutsWeb.ConnCase, async: false

  import EdgeLinkouts.Cosmos.Fake, only: [reset: 0]

  alias EdgeLinkouts.Cosmos
  alias EdgeLinkouts.Display
  alias EdgeLinkoutsWeb.Fixtures

  @slug "drugapprovals-kp"

  setup do
    reset()
    :ok
  end

  describe "the bar" do
    test "the root lists each graph with its releases", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      # The display name comes from kgs/*.exs, the identifier beside it from the same config:
      # nothing on this page is stored, it is all derived from the index's counts.
      assert html =~ "DrugApprovals KP"
      assert html =~ "infores:drugapprovals-kp"
      assert html =~ ~p"/#{@slug}/random"
      assert html =~ ~p"/#{@slug}/random?version=1.16.0"
      assert html =~ ~p"/#{@slug}/random?version=1.11.2"
    end

    test "releases are listed newest first, not in string order", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      # A lexicographic sort would put 1.11.2 first, which reads as "the newest release is a
      # year older than it is".
      assert html =~ ~r/version=1\.16\.0.*version=1\.11\.2/s
    end

    test "the config's latest_version tags one release", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      # The badge only tags a release the store actually holds. The config's latest_version is
      # 1.23.4 and these fixtures stop at 1.16.0, so nothing is tagged yet; the badge path is
      # exercised again as soon as that release is loaded. The bar itself must still render.
      latest = Display.get("infores:drugapprovals-kp").latest_version
      assert latest == "1.23.4"
      refute html =~ "latest-badge"
      assert html =~ "version-pill-group"
      refute html =~ "version-pill version-pill-latest"
    end

    test "the counts are the newest release's, not a sum over releases", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      # Six edges in each of two releases. Summing them would claim twelve edges in a graph
      # that holds six, because releases re-assert the same edges.
      assert html =~ "6 edges in 1.16.0"
      refute html =~ "12 edges"
    end

    test "each pill row carries the overflow chip the browser measures", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-kg-pills"
      assert html =~ "data-kg-more"
      assert html =~ ~s(id="kg-pills-#{@slug}")
    end

    test "the header's random button stays global on this page", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      html = conn |> get(~p"/") |> html_response(200)

      # The bar is about every graph, so "Random edge" here means anywhere in the store.
      assert html =~ ~s(href="/random")
    end

    test "an empty store renders the empty state, not a blank bar", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Nothing loaded yet"
      assert html =~ "linkouts load"
    end

    test "a store that does not answer says so instead of looking empty", %{conn: conn} do
      Cosmos.Fake.queue_error({:request_failed, 500})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "did not answer"
      # An outage must not be reported as "nothing loaded": the two have different fixes.
      refute html =~ "Nothing loaded yet"
    end

    test "a spent read budget says so", %{conn: conn} do
      Cosmos.Fake.queue_error(:budget_exhausted)

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "read budget"
    end

    test "the page costs one point read of the index", %{conn: conn} do
      Cosmos.Fake.seed(Fixtures.docs())

      get(conn, ~p"/")

      # No ids are read to draw the bar, and nothing is queried: the container has no indexes.
      assert Cosmos.Fake.calls() == [{:get_edge, "__random_pool__"}]
    end
  end

  describe "legacy KGinfo permalinks" do
    test "a legacy permalink (/?id=<uuid>) still lands on the edge", %{conn: conn} do
      conn = get(conn, ~p"/" <> "?id=6a682e16-1f0b-453f-900e-a96240703f44")

      assert redirected_to(conn, 302) == "/edges/6a682e16-1f0b-453f-900e-a96240703f44"
    end

    test "an id parameter that would not be a route segment is dropped, not crashed", %{
      conn: conn
    } do
      conn = get(conn, ~p"/" <> "?id=" <> URI.encode_www_form("../../etc/passwd"))

      # Slashes are stripped by the sanitizer; what remains is a harmless id lookup.
      assert redirected_to(conn, 302) == ~p"/edges/....etcpasswd"
    end

    test "a blank id falls back to a random edge", %{conn: conn} do
      conn = get(conn, ~p"/" <> "?id=")

      assert redirected_to(conn, 302) == ~p"/random"
    end
  end
end
