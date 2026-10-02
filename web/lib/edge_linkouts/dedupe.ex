defmodule EdgeLinkouts.Dedupe do
  @moduledoc """
  Collapses concurrent identical reads: one Cosmos read per document id, not one per caller.

  Two browsers opening the same edge within a millisecond must produce one backend call.
  `execute/3` makes the first caller the leader, which runs the function; concurrent
  callers for the same id wait and receive the leader's exact result. The result is shared
  by message, not cached: this is request coalescing, not an HTTP cache (PLAN.md D5).

  Failure handling:

  - The leader crashing (or its function raising/exiting) notifies waiters, which fall
    through to their own direct call.
  - A waiter's wait is bounded (`:wait_ms`, default 500); on timeout it deregisters and
    calls directly rather than blocking a LiveView forever.
  - Every claim and every waiter is monitored, so a crashed process leaves no entry.

  Recent results:

  A LiveView page view mounts twice, once for the static HTTP render and once for the connected
  process, a few hundred milliseconds apart. Coalescing alone cannot merge those, because the
  first read has finished before the second starts, so every page view cost two Cosmos reads.
  Successful results are therefore kept for `:ttl_ms` (default 30 s, PLAN.md D5) in a public ETS
  table that callers read directly, without a GenServer round trip. Only `{:ok, _}` is kept: a
  404, a throttle or an outage is retried rather than replayed for 30 seconds. The table is
  bounded by `:max_entries`; when it is full, expired entries are swept, and if it is still full
  the new result is not stored. Nothing is ever evicted early, so the bound costs only hit rate.

  Stored documents change only when the CLI loads a new release. A page opened in the first 30 s
  after a load can show the previous release, which costs nothing because the version switcher
  still lists what the blob held when it was read.

  Single node by design: the app runs as one Fly machine, so there is no `:global`.
  """

  use GenServer

  @default_wait_ms 500
  @default_ttl_ms 30_000
  @default_max_entries 10_000

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Runs `fun` once for all concurrent callers that pass the same `id`.

  Returns exactly what `fun` returns. If this process is not the leader, it waits up to
  the configured `:wait_ms` for the leader's result, then calls `fun` itself.
  """
  @spec execute(term(), (-> result), GenServer.name()) :: result when result: var
  def execute(id, fun, server \\ __MODULE__) do
    case recent(server, id) do
      {:ok, result} ->
        result

      :miss ->
        case GenServer.call(server, {:begin, id}) do
          {:leader, key} -> lead(key, fun, server)
          {:wait, key, wait_ms} -> wait(key, fun, wait_ms, server)
        end
    end
  end

  @doc "Drops every recent result. For tests, and for an operator after a load."
  @spec clear(GenServer.name()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  # Read the recent-results table from the calling process. A miss, an expired entry, or a server
  # that is not running all fall through to a normal read.
  defp recent(server, id) do
    with name when is_atom(name) <- server,
         table when table != :undefined <- :ets.whereis(table_name(name)),
         [{^id, result, expires_at}] <- :ets.lookup(table, id),
         true <- System.monotonic_time(:millisecond) < expires_at do
      {:ok, result}
    else
      _ -> :miss
    end
  end

  defp table_name(server), do: :"#{server}.recent"

  defp lead(key, fun, server) do
    result = fun.()
    # A call, not a cast: the result must be in the recent-results table before this process
    # returns, or the connected mount that follows the static render races past the insert and
    # reads Cosmos a second time.
    :ok = GenServer.call(server, {:done, key, result})
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

  defstruct claims: %{},
            wait_ms: @default_wait_ms,
            ttl_ms: @default_ttl_ms,
            max_entries: @default_max_entries,
            table: nil

  @impl true
  def init(opts) do
    wait_ms =
      Keyword.get_lazy(opts, :wait_ms, fn ->
        Application.get_env(:edge_linkouts, :dedupe_wait_ms, @default_wait_ms)
      end)

    ttl_ms =
      Keyword.get_lazy(opts, :ttl_ms, fn ->
        Application.get_env(:edge_linkouts, :dedupe_ttl_ms, @default_ttl_ms)
      end)

    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    # Public for reads, so the hot path never waits on this process; only the server writes.
    table =
      :ets.new(table_name(Keyword.fetch!(opts, :name)), [
        :set,
        :named_table,
        :protected,
        read_concurrency: true
      ])

    {:ok, %__MODULE__{wait_ms: wait_ms, ttl_ms: ttl_ms, max_entries: max_entries, table: table}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
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

  def handle_call({:done, key, result}, _from, state) do
    case fetch_claim(state, key) do
      nil ->
        {:reply, :ok, state}

      {id, _claim} = entry ->
        remember(state, id, result)
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
  defp remember(%{ttl_ms: ttl}, _id, _result) when ttl <= 0, do: :ok

  defp remember(state, id, {:ok, _} = result) do
    if room?(state) do
      :ets.insert(state.table, {id, result, System.monotonic_time(:millisecond) + state.ttl_ms})
    end

    :ok
  end

  defp remember(_state, _id, _result), do: :ok

  defp room?(state) do
    :ets.info(state.table, :size) < state.max_entries or sweep(state) < state.max_entries
  end

  # Deletes expired entries and returns the remaining size.
  defp sweep(state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ets.info(state.table, :size)
  end

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
