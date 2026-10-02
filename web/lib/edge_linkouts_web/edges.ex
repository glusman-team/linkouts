defmodule EdgeLinkoutsWeb.Edges do
  @moduledoc """
  The single Cosmos read path for the web app.

  Every page view goes through `fetch_edge/1` (or `fetch_pool/0` for `/random`) exactly
  once, no matter how many components need the document: the LiveView keeps the decoded
  blob in its assigns, so switching `?version=` re-resolves locally and never touches the
  backend again. Reads are coalesced (`Dedupe.execute/3`), so N browsers asking for the same id
  within a millisecond produce one backend call. The RU budget is enforced by the transport
  (`EdgeLinkouts.Cosmos.HTTP`), which knows the real request charge.
  """

  alias EdgeLinkouts.{Cosmos, Dedupe}

  @doc """
  One point read of an edge document.

  Returns `{:error, :rate_limited}` for every capacity refusal: the local RU budget is spent, or
  Cosmos answered 429 twice. Other failures pass through from the backend.
  """
  @spec fetch_edge(String.t()) :: {:ok, stored :: map()} | {:error, term()}
  def fetch_edge(id) when is_binary(id) do
    read(id, fn -> Cosmos.impl().get_edge(id) end)
  end

  @doc "One point read of the reserved `__random_pool__` document that backs /random."
  @spec fetch_pool() :: {:ok, [String.t()]} | {:error, term()}
  def fetch_pool do
    read(Cosmos.reserved_pool_id(), fn -> Cosmos.impl().random_pool() end)
  end

  # Coalescing only. Budget accounting lives in exactly one place, the transport: Cosmos.HTTP gates
  # on RateLimiter.allow?/2 before each attempt and charges the real x-ms-request-charge after.
  # Gating and charging here as well spent every read twice against the 450 RU/s budget, half of
  # it as a guess.
  #
  # Every way a read can be refused for capacity collapses to {:error, :rate_limited}, so the page
  # tells the user to retry. Before, Cosmos.HTTP's :budget_exhausted and {:throttled, ms} fell
  # through to the generic branch and the page said the store could not be reached, which
  # misdirects anyone looking into it.
  defp read(id, call) do
    case Dedupe.execute(id, call) do
      {:error, reason} when reason == :budget_exhausted -> {:error, :rate_limited}
      {:error, {:throttled, _retry_after_ms}} -> {:error, :rate_limited}
      other -> other
    end
  end
end
