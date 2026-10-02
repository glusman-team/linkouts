defmodule EdgeLinkoutsWeb.Edges do
  @moduledoc """
  The single Cosmos read path for the web app.

  Every page view goes through `fetch_edge/1` (or `fetch_pool/0` for `/random`) exactly
  once, no matter how many components need the document: the LiveView keeps the decoded
  blob in its assigns, so switching `?version=` re-resolves locally and never touches the
  backend again. The read itself is wrapped in the RU budget (`RateLimiter.allow?/2`
  before, `charge/2` after) and in-flight coalescing (`Dedupe.execute/3`), so N browsers
  asking for the same id within a millisecond produce one backend call.
  """

  alias EdgeLinkouts.{Cosmos, Dedupe, RateLimiter}

  @doc """
  One point read of an edge document, or `{:error, :rate_limited}` when the current
  window's RU budget cannot fit it. Other failures pass through from the backend.
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

  defp read(id, call) do
    limiter = Application.get_env(:edge_linkouts, :rate_limiter, EdgeLinkouts.RateLimiter)
    # A refused request is charged nothing and the Fake has no request charge, so the
    # estimate is also what gets booked; real HTTP responses reconcile with the actual
    # x-ms-request-charge only inside Cosmos.HTTP.
    estimate = Application.get_env(:edge_linkouts, :cosmos_estimated_read_ru, 10)

    if RateLimiter.allow?(estimate, limiter) do
      result = Dedupe.execute(id, call)
      RateLimiter.charge(estimate, limiter)
      result
    else
      {:error, :rate_limited}
    end
  end
end
