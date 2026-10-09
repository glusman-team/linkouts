defmodule EdgeLinkouts.ClusterTwoNodeTest do
  @moduledoc """
  Real two-node proofs, run with `mix test --include cluster` (excluded by default because
  they start distribution on loopback and take seconds, not milliseconds).

  Covers the two cluster guarantees the read path relies on:

  - a hot edge id is coalesced once across the whole cluster, not once per node
    (the id's ring owner runs the single-flight; the other node routes to it);
  - the membership count the RU limiter divides by tracks a joining node.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  alias EdgeLinkouts.{Cache, Cluster, Dedupe, RateLimiter}

  setup do
    # Shortnames on the machine hostname (resolved via /etc/hosts); 127.0.0.1 as a host
    # only works with longnames, which OTP refuses when the local hostname has no domain.
    unless Node.alive?() do
      {:ok, host} = :inet.gethostname()
      {:ok, _} = Node.start(:"main@#{host}", :shortnames)
    end

    # The test app booted with distribution off, so the main cache's ring holds a stale
    # :nonode@nohost member. Restart it under the now-live distribution (in production the
    # release starts distribution before the application, so this cannot happen there).
    _ = Supervisor.restart_child(EdgeLinkouts.Supervisor, EdgeLinkouts.Cache)

    peer_args = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    # A fresh name per test: reusing one across sequential tests races epmd re-registration
    # and leaves the previous dead node's ring entry ambiguous with the new peer's.
    peer_name = :"peer_#{System.unique_integer([:positive])}"
    {:ok, peer, peer_node} = :peer.start_link(%{name: peer_name, args: peer_args})

    # The stack boots in one detached peer process: any rpc/erpc worker exits after the
    # call, and a service start_link'ed to such a worker would die with it.
    :ok = :rpc.call(peer_node, EdgeLinkouts.ClusterPeer, :boot, [])

    assert_eventually(fn -> :rpc.call(peer_node, Process, :whereis, [Cache]) != nil end)
    assert_eventually(fn -> :rpc.call(peer_node, Process, :whereis, [Cluster]) != nil end)

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        # The peer may already be dead (test process exit kills the linked peer first).
        _, _ -> :ok
      end
    end)

    [peer_node: peer_node]
  end

  test "one backend read for the same hot id across both nodes", %{peer_node: peer_node} do
    # Ring discovery is asynchronous; wait until the ring is exactly this node and the peer
    # (a previous test's dead peer may linger in the ring until its pg leave propagates).
    assert_ring([node(), peer_node])

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    key = live_owned_key(peer_node)
    fetch = {EdgeLinkouts.ClusterPeer, :slow_counted_fetch, [counter]}

    from_main =
      for _ <- 1..10 do
        Task.async(fn -> Dedupe.execute(key, fetch) end)
      end

    from_peer =
      for _ <- 1..10 do
        Task.async(fn ->
          :erpc.call(peer_node, Dedupe, :execute, [key, fetch, Dedupe, []])
        end)
      end

    results = Enum.map(from_main ++ from_peer, &Task.await(&1, 10_000))

    assert Enum.uniq(results) == [:ok]
    assert Agent.get(counter, & &1) == 1
  end

  test "a joining peer raises the live node count to 2", %{peer_node: peer_node} do
    assert_eventually(fn -> Cluster.node_count() == 2 end)
    assert_eventually(fn -> :erpc.call(peer_node, Cluster, :node_count, []) == 2 end)
  end

  test "a cache write on one node is readable from the other", %{peer_node: peer_node} do
    assert_ring([node(), peer_node])

    :ok = Cache.put("shared-key", "shared-value")
    assert :rpc.call(peer_node, Cache, :get, ["shared-key"]) == {:ok, "shared-value"}
  end

  test "the RU budget is divided by the live node count", %{peer_node: _peer_node} do
    assert_eventually(fn -> Cluster.node_count() == 2 end)

    # Per-node budget is the configured total divided by the live node count (direnv sets
    # RU_BUDGET_WEB=450 locally, fly.toml sets 150 in prod), so derive expectations from
    # the actual config instead of hardcoding either value.
    total = Application.get_env(:edge_linkouts, :ru_budget_web)
    per_node = div(total, 2)

    :ok = RateLimiter.charge(per_node - 10)
    # per_node - 10 + 11 exceeds the halved budget; per_node - 10 + 9 fits it.
    refute RateLimiter.allow?(11)
    assert RateLimiter.allow?(9)
  end

  # The test VM starts distribution AFTER the app (mix test boots the app first), so the
  # cache ring can carry a stale :nonode@nohost member until the next membership event
  # heals it. Production boots distribution before the application, so the artifact is
  # impossible there; tolerate exactly that one entry here and nothing else.
  defp assert_ring(expected) do
    assert_eventually(fn ->
      ring = Cache.nodes()

      Enum.all?(expected, &(&1 in ring)) and
        Enum.all?(ring -- expected, &(&1 == :nonode@nohost))
    end)
  end

  # A key whose ring owner is a live node: a key hashing to the stale :nonode@nohost entry
  # would fall back to local reads on both nodes and could double-count the backend fetch.
  defp live_owned_key(peer_node) do
    Enum.find_value(1..1000, fn i ->
      key = "hot-edge-#{i}"

      case Cache.find_node(key) do
        {:ok, owner} when owner == peer_node or owner == node() -> key
        _other -> nil
      end
    end) || raise "no live-owned key found in 1000 tries"
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(100)
      assert_eventually(fun, attempts - 1)
    end
  end
end
