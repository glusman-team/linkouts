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

  Single node by design: the app runs as one Fly machine, so there is no `:global`.
  """

  use GenServer

  @default_wait_ms 500

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
    case GenServer.call(server, {:begin, id}) do
      {:leader, key} -> lead(key, fun, server)
      {:wait, key, wait_ms} -> wait(key, fun, wait_ms, server)
    end
  end

  defp lead(key, fun, server) do
    result = fun.()
    GenServer.cast(server, {:done, key, result})
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

  defstruct claims: %{}, wait_ms: @default_wait_ms

  @impl true
  def init(opts) do
    wait_ms =
      Keyword.get_lazy(opts, :wait_ms, fn ->
        Application.get_env(:edge_linkouts, :dedupe_wait_ms, @default_wait_ms)
      end)

    {:ok, %__MODULE__{wait_ms: wait_ms}}
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

  @impl true
  def handle_cast({:done, key, result}, state) do
    case fetch_claim(state, key) do
      nil -> {:noreply, state}
      entry -> {:noreply, finish(entry, {:dedupe_result, key, result}, state)}
    end
  end

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
