defmodule EdgeLinkouts.Dedupe do
  @moduledoc """
  Collapses concurrent identical reads: one Cosmos read per document id, not one per caller,
  and replays recent successes from `EdgeLinkouts.Cache`.

  Two browsers opening the same edge within a millisecond must produce one backend call.
  `execute/3` makes the first caller the leader, which runs the function; concurrent
  callers for the same id wait and receive the leader's exact result. The result is shared
  by message, not cached: the coalescing half is request dedupe, not an HTTP cache
  (PLAN.md D5).

  Failure handling:

  - The leader crashing (or its function raising/exiting) notifies waiters, which fall
    through to their own direct call.
  - A waiter's wait is bounded (`:wait_ms`, default 500); on timeout it deregisters and
    calls directly rather than blocking a LiveView forever.
  - Every claim and every waiter is monitored, so a crashed process leaves no entry.

  Recent results:

  A LiveView page view mounts twice, once for the static HTTP render and once for the
  connected process, a few hundred milliseconds apart. Coalescing alone cannot merge those,
  because the first read has finished before the second starts, so every page view would
  cost two Cosmos reads. Successful results are therefore replayed for `:ttl_ms`
  (default 30 s, PLAN.md D5) from the cache named by the `:cache` option
  (`EdgeLinkouts.Cache` by default); a read may pass `:ttl_ms` to override the default,
  which is how pool documents replay for 15 minutes (see the web read path). Only
  `{:ok, _}` is kept: a 404, a throttle or an outage is retried rather than replayed.

  The cache is read from the calling process, so the hot path never waits on this
  GenServer; the server only writes, and the write is a synchronous call before the leader
  returns, so a connected mount that follows the static render cannot race past the store.

  Single node by design: the app runs as one Fly machine, so there is no `:global`.
  """

  use GenServer

  alias EdgeLinkouts.Cache

  @default_wait_ms 500
  @default_ttl_ms 30_000

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Runs `fun` once for all concurrent callers that pass the same `id`.

  Returns exactly what `fun` returns. If this process is not the leader, it waits up to
  the configured `:wait_ms` for the leader's result, then calls `fun` itself.

  `opts`:

  - `:ttl_ms` — how long a successful result may be replayed, overriding the server default.
    A read of a document the CLI only rewrites on a load (the pool index, one release's pool)
    can be replayed for minutes without showing anything stale to a person; an edge document
    uses the default, so a page view right after a load shows the release that was just loaded.
    The override is ignored when the server's own `:ttl_ms` is zero, which is how tests turn
    caching off: a caller must not be able to switch it back on behind their back.
  """
  @spec execute(term(), (-> result), GenServer.name(), keyword()) :: result when result: var
  def execute(id, fun, server \\ __MODULE__, opts \\ []) do
    case recent(server, id) do
      {:ok, result} ->
        result

      :miss ->
        case GenServer.call(server, {:begin, id}) do
          {:leader, key} -> lead(key, fun, server, Keyword.get(opts, :ttl_ms))
          {:wait, key, wait_ms} -> wait(key, fun, wait_ms, server)
        end
    end
  end

  @doc "Drops every recent result. For tests, and for an operator after a load."
  @spec clear(GenServer.name()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  # Read the recent-results cache from the calling process. A miss, a cache that is not
  # running, or a server that is not running all fall through to a normal read.
  # with_dynamic_cache/2 is how Nebulex v3 scopes calls to a named instance: the leading-arg
  # arities collide with the public defaults (Cache.get(instance, key) would read key=:instance
  # on the default cache), so there is no per-call instance argument.
  defp recent(server, id) do
    case cache_for(server) do
      cache when is_atom(cache) ->
        Cache.with_dynamic_cache(cache, fn ->
          # fetch, not get: get returns {:ok, default} on a miss, which would masquerade as a
          # cached nil and skip the read.
          case Cache.fetch(id) do
            {:ok, result} -> {:ok, result}
            _ -> :miss
          end
        end)

      _ ->
        :miss
    end
  end

  # The cache name is resolved through :persistent_term, not passed through execute/3, so
  # the server side (which stores) and the caller side (which reads) resolve it the same
  # way. Same pattern as EdgeLinkouts.RateLimiter keeping its atomics ref there.
  defp cache_for(server) when is_atom(server) do
    :persistent_term.get({__MODULE__, :cache, server}, nil)
  end

  defp cache_for(_server), do: nil

  defp lead(key, fun, server, ttl_ms) do
    result = fun.()
    # A call, not a cast: the result must be in the cache before this process returns, or
    # the connected mount that follows the static render races past the store and reads
    # Cosmos a second time.
    :ok = GenServer.call(server, {:done, key, result, ttl_ms})
    result
  rescue
    e ->
      GenServer.cast(server, {:crashed, key})
      reraise e, __STACKTRACE__
  catch
    :exit, reason ->
      GenServer.cast(server, {:crashed, key})
      exit(reason)
  end

  defp wait(key, fun, wait_ms, server) do
    receive do
      {:dedupe_result, ^key, result} -> result
      {:leader_down, ^key} -> fun.()
    after
      wait_ms ->
        GenServer.cast(server, {:cancel, key, self()})
        fun.()
    end
  end

  # ---------------------------------------------------------------- server

  defstruct claims: %{}, wait_ms: @default_wait_ms, ttl_ms: @default_ttl_ms, cache: Cache

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    wait_ms =
      Keyword.get_lazy(opts, :wait_ms, fn ->
        Application.get_env(:edge_linkouts, :dedupe_wait_ms, @default_wait_ms)
      end)

    ttl_ms =
      Keyword.get_lazy(opts, :ttl_ms, fn ->
        Application.get_env(:edge_linkouts, :dedupe_ttl_ms, @default_ttl_ms)
      end)

    cache = Keyword.get(opts, :cache, Cache)
    :persistent_term.put({__MODULE__, :cache, name}, cache)

    {:ok, %__MODULE__{wait_ms: wait_ms, ttl_ms: ttl_ms, cache: cache}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    _ = Cache.with_dynamic_cache(state.cache, fn -> Cache.delete_all() end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:begin, id}, {pid, _tag}, %__MODULE__{} = state) do
    case Map.fetch(state.claims, id) do
      :error ->
        key = make_ref()
        claim = %{owner: pid, mon: Process.monitor(pid), key: key, waiters: []}
        {:reply, {:leader, key}, put_claim(state, id, claim)}

      {:ok, claim} ->
        waiter = %{pid: pid, mon: Process.monitor(pid)}
        claim = %{claim | waiters: [waiter | claim.waiters]}
        # Waiters wait on the claim's key, which is what the owner's completion notifies
        # with; per-waiter keys would never match.
        {:reply, {:wait, claim.key, state.wait_ms}, put_claim(state, id, claim)}
    end
  end

  def handle_call({:done, key, result, ttl_ms}, _from, state) do
    case fetch_claim(state, key) do
      nil ->
        {:reply, :ok, state}

      {id, _claim} = entry ->
        remember(state, id, result, ttl_ms)
        {:reply, :ok, finish(entry, {:dedupe_result, key, result}, state)}
    end
  end

  @impl true
  def handle_cast({:crashed, key}, state) do
    case fetch_claim(state, key) do
      nil -> {:noreply, state}
      entry -> {:noreply, finish(entry, {:leader_down, key}, state)}
    end
  end

  def handle_cast({:cancel, key, pid}, state) do
    case fetch_claim(state, key) do
      nil ->
        {:noreply, state}

      {id, claim} ->
        {removed, kept} = Enum.split_with(claim.waiters, &(&1.pid == pid))
        Enum.each(removed, &Process.demonitor(&1.mon, [:flush]))
        {:noreply, put_claim(state, id, %{claim | waiters: kept})}
    end
  end

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    case find_by_monitor(state, mon) do
      {:owner, id, claim} ->
        {:noreply, finish({id, claim}, {:leader_down, claim.key}, state)}

      {:waiter, id, claim, waiter} ->
        Process.demonitor(waiter.mon, [:flush])
        waiters = List.delete(claim.waiters, waiter)
        {:noreply, put_claim(state, id, %{claim | waiters: waiters})}

      nil ->
        {:noreply, state}
    end
  end

  # Sends the outcome to every waiter, drops their monitors, and removes the claim, so a
  # crashed leader or caller never leaves an entry behind.
  defp finish({id, claim}, message, state) do
    Enum.each(claim.waiters, fn waiter ->
      Process.demonitor(waiter.mon, [:flush])
      send(waiter.pid, message)
    end)

    %{state | claims: Map.delete(state.claims, id)}
  end

  # Only successes are kept: a 404, a throttle or an outage must be retried, not replayed.
  # A server-wide ttl of zero disables caching entirely, and a caller's override cannot revive it.
  defp remember(%{ttl_ms: default}, _id, _result, _override) when default <= 0, do: :ok

  defp remember(%{cache: cache} = state, id, {:ok, _} = result, override) do
    ttl = if is_integer(override) and override > 0, do: override, else: state.ttl_ms
    # The instance name (an atom) is resolved by recent/0 through the same :persistent_term
    # entry, so both sides of a store see one cache.
    _ = Cache.with_dynamic_cache(cache, fn -> Cache.put(id, result, ttl: ttl) end)
    :ok
  end

  defp remember(_state, _id, _result, _override), do: :ok

  defp put_claim(state, id, claim), do: %{state | claims: Map.put(state.claims, id, claim)}

  defp fetch_claim(state, key) do
    Enum.find_value(state.claims, fn {id, claim} ->
      if claim.key == key, do: {id, claim}
    end)
  end

  defp find_by_monitor(state, mon) do
    Enum.find_value(state.claims, fn {id, claim} ->
      cond do
        claim.mon == mon -> {:owner, id, claim}
        waiter = Enum.find(claim.waiters, &(&1.mon == mon)) -> {:waiter, id, claim, waiter}
        true -> nil
      end
    end)
  end
end
