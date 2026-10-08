defmodule EdgeLinkoutsWeb.OriginCheckTest do
  use ExUnit.Case, async: false

  # Env is process-global, so these run serially and restore the key around each test.
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias EdgeLinkoutsWeb.OriginCheck

  setup do
    previous = System.get_env("X_ORIGIN_KEY")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("X_ORIGIN_KEY")
        value -> System.put_env("X_ORIGIN_KEY", value)
      end
    end)

    :ok
  end

  test "without the key in the environment the plug is inert" do
    System.delete_env("X_ORIGIN_KEY")
    conn = conn(:get, "/")

    refute OriginCheck.call(conn, []).halted
  end

  test "a request carrying the shared header passes" do
    System.put_env("X_ORIGIN_KEY", "s3cret")
    conn = conn(:get, "/") |> put_req_header("x-origin-key", "s3cret")

    refute OriginCheck.call(conn, []).halted
  end

  test "a request without the header is halted with 403 before any route runs" do
    System.put_env("X_ORIGIN_KEY", "s3cret")
    conn = OriginCheck.call(conn(:get, "/"), [])

    assert conn.halted
    assert conn.status == 403
  end

  test "a request with the wrong header is halted too" do
    System.put_env("X_ORIGIN_KEY", "s3cret")
    conn = conn(:get, "/") |> put_req_header("x-origin-key", "guessed") |> OriginCheck.call([])

    assert conn.halted
    assert conn.status == 403
  end
end
