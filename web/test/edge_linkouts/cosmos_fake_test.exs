defmodule EdgeLinkouts.Cosmos.FakeTest do
  use ExUnit.Case, async: true

  alias EdgeLinkouts.Cosmos

  setup do
    name = :"fake_#{System.unique_integer()}"
    start_supervised!({Cosmos.Fake, name: name})
    %{fake: name}
  end

  test "returns seeded documents by id", %{fake: fake} do
    Cosmos.Fake.seed(%{"id" => "edge-1", "b" => "frame"}, fake)

    assert Cosmos.Fake.get_edge("edge-1", fake) == {:ok, %{"id" => "edge-1", "b" => "frame"}}
  end

  test "an unknown id is :not_found", %{fake: fake} do
    assert Cosmos.Fake.get_edge("nope", fake) == {:error, :not_found}
  end

  test "the next queued failure is consumed exactly once, then the real result follows", %{
    fake: fake
  } do
    Cosmos.Fake.seed(%{"id" => "edge-1", "b" => "frame"}, fake)
    Cosmos.Fake.queue_error({:throttled, 42}, fake)
    Cosmos.Fake.queue_error(:boom, fake)
    Cosmos.Fake.queue_error(:boom, fake)

    assert Cosmos.Fake.get_edge("edge-1", fake) == {:error, {:throttled, 42}}
    assert Cosmos.Fake.get_edge("edge-1", fake) == {:error, :boom}
    assert Cosmos.Fake.get_edge("edge-1", fake) == {:error, :boom}
    assert Cosmos.Fake.get_edge("edge-1", fake) == {:ok, %{"id" => "edge-1", "b" => "frame"}}
  end

  test "random_pool decodes a seeded pool document like the CLI writes it", %{fake: fake} do
    Cosmos.Fake.seed_pool(["a", "b"], fake)

    assert Cosmos.Fake.random_pool(fake) == {:ok, ["a", "b"]}
  end

  test "random_pool without a pool document is :not_found", %{fake: fake} do
    assert Cosmos.Fake.random_pool(fake) == {:error, :not_found}
  end

  test "set_latency delays every call", %{fake: fake} do
    Cosmos.Fake.set_latency(5, fake)
    start = System.monotonic_time(:millisecond)
    Cosmos.Fake.get_edge("edge-1", fake)
    assert System.monotonic_time(:millisecond) - start >= 5
  end

  test "the call log records operations in order", %{fake: fake} do
    Cosmos.Fake.seed(%{"id" => "edge-1", "b" => "frame"}, fake)
    Cosmos.Fake.get_edge("edge-1", fake)
    Cosmos.Fake.get_edge("edge-2", fake)
    Cosmos.Fake.random_pool(fake)

    assert Cosmos.Fake.calls(fake) == [
             {:get_edge, "edge-1"},
             {:get_edge, "edge-2"},
             :random_pool
           ]
  end

  test "reset clears documents, failures, latency and the log", %{fake: fake} do
    Cosmos.Fake.seed(%{"id" => "edge-1", "b" => "frame"}, fake)
    Cosmos.Fake.queue_error(:boom, fake)
    Cosmos.Fake.set_latency(1, fake)
    Cosmos.Fake.get_edge("edge-1", fake)

    assert Cosmos.Fake.reset(fake) == :ok
    assert Cosmos.Fake.get_edge("edge-1", fake) == {:error, :not_found}
    assert Cosmos.Fake.calls(fake) == [{:get_edge, "edge-1"}]
  end
end
