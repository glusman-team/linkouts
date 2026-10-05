defmodule EdgeLinkoutsWeb.EdgeControllerTest do
  use EdgeLinkoutsWeb.ConnCase, async: false

  alias EdgeLinkouts.Codec
  alias EdgeLinkouts.Cosmos
  alias EdgeLinkoutsWeb.Fixtures

  @v1 Fixtures.v1()
  @v2 Fixtures.v2()

  setup do
    Cosmos.Fake.reset()
    Cosmos.Fake.seed(Fixtures.docs())

    %{id: Fixtures.first_edge_id()}
  end

  test "downloads an attachment whose body is byte-identical to the canonical newest document", %{
    conn: conn,
    id: id
  } do
    conn = get(conn, "/edges/#{id}/download")

    assert response(conn, 200) == canonical_at(id, @v2)

    assert get_resp_header(conn, "content-type") == ["application/x-ndjson"]

    [disposition] = get_resp_header(conn, "content-disposition")
    # The version key's colon is illegal in a Windows filename, so the download name turns it
    # into a hyphen; the body and the ?version= parameter keep the canonical key.
    assert disposition ==
             ~s(attachment; filename="edge-#{id}-infores-drugapprovals-kp-1.16.0.ndjson")
  end

  test "?version selects that stored version", %{conn: conn, id: id} do
    conn = get(conn, "/edges/#{id}/download?version=#{@v1}")

    assert response(conn, 200) == canonical_at(id, @v1)
  end

  test "an unknown id answers HTTP 404", %{conn: conn} do
    conn = get(conn, "/edges/00000000-0000-0000-0000-000000000000/download")

    assert html_response(conn, 404) =~ "edge id was not found"
  end

  test "an unknown version answers HTTP 404", %{conn: conn, id: id} do
    conn = get(conn, "/edges/#{id}/download?version=nope-9.9.9")

    assert html_response(conn, 404) =~ "edge id was not found"
  end

  defp canonical_at(id, key) do
    Fixtures.edge_doc(id) |> Fixtures.resolved(key) |> Codec.canonical_binary()
  end
end
