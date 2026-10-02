defmodule EdgeLinkouts.DedupeTest do
  use ExUnit.Case, async: true

  alias EdgeLinkouts.{Cosmos, Dedupe}

  setup do
    fake = :"fake_#{System.unique_integer()}"
    start_supervised!({Cosmos.Fake, name: fake})
    %{fake: fake}
  end

  defp start_dedupe(opts \\ []) do
    name = :"dedupe_#{System.unique_integer()}"
    start_supervised!({Dedupe, Keyword.put(opts, :name, name)})
    name
  end

  test "N concurrent readers of one id produce exactly one backend call", %{fake: fake} do
    dedupe = start_dedupe()
    id = "edge-1"
    doc = %{"id" => id, "b" => "frame"}
    Cosmos.Fake.seed(doc, fake)
    # Long enough that every spawned reader lands inside the leader's call.
    Cosmos.Fake.set_latency(50, fake)

    results =
      for _ <- 1..8 do
        Task.async(fn -> Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe) end)
      end
      |> Task.await_many()

    assert Enum.uniq(results) == [{:ok, doc}]
    # The point: one read per page view, not one per component (PLAN.md D5).
    assert Cosmos.Fake.calls(fake) == [{:get_edge, id}]
  end

  test "different ids are not collapsed", %{fake: fake} do
    dedupe = start_dedupe()
    ids = for n <- 1..5, do: "edge-#{n}"
    Cosmos.Fake.set_latency(20, fake)

    for id <- ids do
      Cosmos.Fake.seed(%{"id" => id, "b" => "frame"}, fake)
    end

    results =
      for id <- ids do
        Task.async(fn -> Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe) end)
      end
      |> Task.await_many()

    assert length(results) == 5
    assert Cosmos.Fake.calls(fake) |> length() == 5
  end

  test "a waiter whose leader fails receives the leader's error without a second call", %{
    fake: fake
  } do
    dedupe = start_dedupe()
    id = "edge-1"
    Cosmos.Fake.set_latency(50, fake)
    Cosmos.Fake.queue_error(:boom, fake)

    tasks =
      for _ <- 1..3 do
        Task.async(fn -> Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe) end)
      end
      |> Task.await_many()

    assert Enum.uniq(tasks) == [{:error, :boom}]
    assert Cosmos.Fake.calls(fake) |> length() == 1
  end

  test "a waiter falls through to a direct read when its wait bound expires", %{fake: fake} do
    dedupe = start_dedupe(wait_ms: 50)
    id = "edge-1"
    Cosmos.Fake.seed(%{"id" => id, "b" => "frame"}, fake)

    leader =
      Task.async(fn ->
        Dedupe.execute(
          id,
          fn ->
            Process.sleep(300)
            Cosmos.Fake.get_edge(id, fake)
          end,
          dedupe
        )
      end)

    # Let the leader claim the id, then join it as a waiter.
    Process.sleep(20)

    {waiter_ms, waiter_result} =
      :timer.tc(fn ->
        Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe)
      end)

    assert waiter_result == {:ok, %{"id" => id, "b" => "frame"}}
    # Did not wait for the leader's full 300 ms.
    assert waiter_ms < 250_000

    Task.await(leader, 2_000)
    assert Cosmos.Fake.calls(fake) |> length() == 2
  end

  test "a waiter falls through when the leader crashes mid-read", %{fake: fake} do
    dedupe = start_dedupe()
    id = "edge-1"
    Cosmos.Fake.seed(%{"id" => id, "b" => "frame"}, fake)

    spawn(fn ->
      Dedupe.execute(id, fn -> raise "leader explodes" end, dedupe)
    end)

    Process.sleep(20)

    assert Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe) ==
             {:ok, %{"id" => id, "b" => "frame"}}

    # Only the fall-through read hit the backend; the crashed leader never did.
    assert Cosmos.Fake.calls(fake) == [{:get_edge, id}]
  end

  test "a finished claim is removed, so a later read runs again", %{fake: fake} do
    dedupe = start_dedupe()
    id = "edge-1"
    Cosmos.Fake.seed(%{"id" => id, "b" => "frame"}, fake)

    fun = fn -> Cosmos.Fake.get_edge(id, fake) end
    assert {:ok, _} = Dedupe.execute(id, fun, dedupe)
    assert {:ok, _} = Dedupe.execute(id, fun, dedupe)

    assert Cosmos.Fake.calls(fake) |> length() == 2
  end
end
