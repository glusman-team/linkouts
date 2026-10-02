defmodule EdgeLinkouts.Cosmos do
  @moduledoc """
  Read-only access to the Cosmos DB edge documents.

  The behaviour has exactly two operations, both point reads: one edge document by id and
  the reserved `__random_pool__` document. The web app never writes: the only credential
  configured here is the account's read-only key.

  `get_edge/1` returns the *stored* document (`%{"id" => ..., "b" => ..., "d" => ...}`),
  not a decoded blob: decoding needs the display configuration and the zstd dictionary,
  which is `EdgeLinkouts.Codec`'s concern, not transport's.

  Backends:

  - `EdgeLinkouts.Cosmos.HTTP` - Finch + master-key HMAC, selected in production.
  - `EdgeLinkouts.Cosmos.File` - NDJSON file written by the CLI's file store, for dev.
  - `EdgeLinkouts.Cosmos.Fake` - in-memory, programmable failures, started only in tests.

  The backend is resolved per call from `config :edge_linkouts, :cosmos_backend` so tests
  can swap it without recompiling.
  """

  @callback get_edge(id :: String.t()) :: {:ok, stored :: map()} | {:error, term()}
  @callback random_pool() :: {:ok, [String.t()]} | {:error, term()}

  @reserved_pool_id "__random_pool__"

  @doc "The reserved document id that backs /random (see docs/adr/0001-wire-format.md)."
  @spec reserved_pool_id() :: String.t()
  def reserved_pool_id, do: @reserved_pool_id

  @doc "The configured backend module; defaults to the real HTTP client."
  @spec impl() :: module()
  def impl do
    Application.get_env(:edge_linkouts, :cosmos_backend, EdgeLinkouts.Cosmos.HTTP)
  end

  @doc """
  The trained zstd dictionary bytes to decompress with, or `nil` when none is configured.

  Selected with `config :edge_linkouts, :zstd_dict_path` (a path to a dictionary the CLI
  trained). The file is read once and cached; a stored document whose `d` does not match
  this dictionary fails loudly inside `EdgeLinkouts.Codec` instead of rendering garbage.
  """
  @spec dictionary() :: binary() | nil
  def dictionary do
    case Application.get_env(:edge_linkouts, :zstd_dict_path) do
      nil ->
        nil

      path ->
        cache_key = {__MODULE__, :zstd_dictionary}

        case :persistent_term.get(cache_key, :missing) do
          :missing ->
            dictionary = File.read!(path)
            :persistent_term.put(cache_key, dictionary)
            dictionary

          dictionary ->
            dictionary
        end
    end
  end

  @doc """
  Decodes a stored `__random_pool__` document into its id list.

  Shared by the HTTP and File backends. The dictionary is only loaded when the document
  declares one (`d` present and non-zero); a missing dictionary for a dict-compressed
  frame is an error from `:zstd`, which is the loud failure ADR 0001 asks for.
  """
  @doc since: "0.1.0"
  @doc section: :internal
  @spec decode_pool_doc(map()) :: {:ok, [String.t()]} | {:error, term()}
  def decode_pool_doc(%{"b" => b64} = doc) do
    dictionary =
      case Map.get(doc, "d") do
        nil -> nil
        0 -> nil
        _dict_id -> dictionary()
      end

    case EdgeLinkouts.Codec.decode_pool(b64, dictionary) do
      {:ok, pool} -> {:ok, pool.ids}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_pool_doc(other), do: {:error, {:not_a_pool_doc, other}}
end
