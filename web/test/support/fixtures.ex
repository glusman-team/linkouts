defmodule EdgeLinkoutsWeb.Fixtures do
  @moduledoc """
  The committed contract fixtures, plus stored-document builders for synthetic blobs.

  Tests seed `EdgeLinkouts.Cosmos.Fake` from the real stored data (docs.ndjson) rather
  than inventing documents. The blob builder exists for cases the fixtures cannot
  express - a hostile subject name, or a blob with a specific added/removed/changed
  field triple - and encodes exactly the documented ADR 0001 wire format.
  """

  alias EdgeLinkouts.Codec

  @docs_path Path.expand("../fixtures/contract/docs.ndjson", __DIR__)

  @v1 "drug-approvals-kg-1.11.2"
  @v2 "drug-approvals-kg-1.16.0"

  def v1, do: @v1
  def v2, do: @v2

  @doc "Every stored document in docs.ndjson, including the reserved pool document."
  def docs, do: read(@docs_path)

  def edge_docs, do: Enum.reject(docs(), &(&1["id"] == EdgeLinkouts.Cosmos.reserved_pool_id()))

  def first_edge_id, do: hd(edge_docs())["id"]

  def edge_doc(id), do: Enum.find(edge_docs(), &(&1["id"] == id))

  @doc "The resolved document for a stored fixture document at a version key."
  def resolved(%{"b" => b64}, key) do
    {:ok, blob} = Codec.decode(b64)
    {:ok, doc} = Codec.resolve(blob, key)
    doc
  end

  @doc """
  Encodes version payloads as one stored blob document (`{"id", "b"}`), the way the CLI
  writes them: canonical-ish JSON, one zstd frame, base64. Only decode is exercised by
  the reader, so building is plain `JSON.encode!/1`.
  """
  def stored(id, versions) do
    frame =
      %{"schema" => "edgelinkouts.blob/1", "versions" => versions}
      |> JSON.encode!()
      |> :zstd.compress()
      |> IO.iodata_to_binary()

    %{"id" => id, "b" => Base.encode64(frame)}
  end

  defp read(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&JSON.decode!/1)
  end
end
