defmodule EdgeLinkouts.DedupeTest do
  use ExUnit.Case, async: true

  alias EdgeLinkouts.{Cosmos, Dedupe}

  setup do
    fake = :"fake_#{System.unique_integer()}"
    start_supervised!({Cosmos.Fake, name: fake})
    %{fake: fake}
  end

  # Coalescing tests run with the result cache off, so a cached result cannot hide a backend call.
  # The cache has its own describe block below.
  defp start_dedupe(opts \\ []) do
    name = :"dedupe_#{System.unique_integer([:positive])}"
    opts = opts |> Keyword.put(:name, name) |> Keyword.put_new(:ttl_ms, 0)
    start_supervised!({Dedupe, opts})
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

  describe "recent results" do
    setup %{fake: fake} do
      Cosmos.Fake.seed(%{"id" => "e1", "b" => "x"}, fake)
      :ok
    end

    defp read(dedupe, fake, id),
      do: Dedupe.execute(id, fn -> Cosmos.Fake.get_edge(id, fake) end, dedupe)

    test "the LiveView double mount costs one backend read, not two", %{fake: fake} do
      # Static render, then the connected mount a moment later: sequential, so coalescing alone
      # cannot merge them.
      dedupe = start_dedupe(ttl_ms: 30_000)

      assert {:ok, _} = read(dedupe, fake, "e1")
      assert {:ok, _} = read(dedupe, fake, "e1")

      assert Cosmos.Fake.calls(fake) == [{:get_edge, "e1"}]
    end

    test "a failure is not remembered, so the next view retries", %{fake: fake} do
      dedupe = start_dedupe(ttl_ms: 30_000)

      assert {:error, :not_found} = read(dedupe, fake, "missing")
      assert {:error, :not_found} = read(dedupe, fake, "missing")
      assert length(Cosmos.Fake.calls(fake)) == 2

      Cosmos.Fake.queue_error({:throttled, 100}, fake)
      assert {:error, {:throttled, 100}} = read(dedupe, fake, "e1")
      assert {:ok, _} = read(dedupe, fake, "e1")
    end

    test "results expire after the ttl", %{fake: fake} do
      dedupe = start_dedupe(ttl_ms: 20)

      assert {:ok, _} = read(dedupe, fake, "e1")
      Process.sleep(40)
      assert {:ok, _} = read(dedupe, fake, "e1")

      assert length(Cosmos.Fake.calls(fake)) == 2
    end

    test "a full table stops remembering instead of evicting", %{fake: fake} do
      Cosmos.Fake.seed(%{"id" => "e2", "b" => "y"}, fake)
      dedupe = start_dedupe(ttl_ms: 30_000, max_entries: 1)

      assert {:ok, _} = read(dedupe, fake, "e1")
      assert {:ok, _} = read(dedupe, fake, "e2")
      # e1 kept its slot; e2 found the table full and was not stored.
      assert {:ok, _} = read(dedupe, fake, "e1")
      assert {:ok, _} = read(dedupe, fake, "e2")

      assert Cosmos.Fake.calls(fake) == [{:get_edge, "e1"}, {:get_edge, "e2"}, {:get_edge, "e2"}]
    end

    test "clear/1 forgets everything", %{fake: fake} do
      dedupe = start_dedupe(ttl_ms: 30_000)

      assert {:ok, _} = read(dedupe, fake, "e1")
      :ok = Dedupe.clear(dedupe)
      assert {:ok, _} = read(dedupe, fake, "e1")

      assert length(Cosmos.Fake.calls(fake)) == 2
    end
  end
end
