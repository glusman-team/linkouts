defmodule EdgeLinkoutsWeb.HomeLiveTest do
  use EdgeLinkoutsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # No Cosmos read at all: the home page reads display configs, so it must render with
  # an empty store (and this test never touches the shared Fake).
  test "lists the configured knowledge graphs with descriptions and source links", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Knowledge graphs"
    assert html =~ "Multiomics Drug Approvals"
    assert html =~ "regulatory approvals of drug"

    assert html =~
             "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP"
  end

  test "links to /random as 'show me a random relationship'", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(href="/random")
    assert html =~ "show me a random relationship"
  end
end
