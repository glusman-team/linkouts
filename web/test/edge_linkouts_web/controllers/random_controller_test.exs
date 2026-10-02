defmodule EdgeLinkoutsWeb.RandomControllerTest do
  use EdgeLinkoutsWeb.ConnCase, async: false

  alias EdgeLinkouts.Cosmos
  alias EdgeLinkoutsWeb.Fixtures

  setup do
    Cosmos.Fake.reset()
    :ok
  end

  test "responds 302 with a location matching /edges/<uuid> for a seeded pool", %{conn: conn} do
    Cosmos.Fake.seed(Fixtures.docs())

    conn = get(conn, "/random")

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert Regex.match?(~r|^/edges/[0-9a-f-]{36}$|, location)
  end

  test "redirects to / when the pool is missing", %{conn: conn} do
    conn = get(conn, "/random")

    assert conn.status == 302
    assert redirected_to(conn, 302) == "/"
  end

  test "redirects to / when the pool is empty", %{conn: conn} do
    Cosmos.Fake.seed_pool([])

    conn = get(conn, "/random")

    assert conn.status == 302
    assert redirected_to(conn, 302) == "/"
  end
end
