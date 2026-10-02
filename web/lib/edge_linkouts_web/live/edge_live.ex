defmodule EdgeLinkoutsWeb.EdgeLive do
  @moduledoc """
  The linkout page for one edge: the display-config sentence, the relationship diagram,
  the version switcher, the diff against the previous version, and the evidence panel.

  One Cosmos read per page view: `mount/3` reads nothing, and `handle_params/3` only calls
  the backend when the id changed. The blob carries every stored version, so switching
  `?version=` re-resolves from the assigns and never triggers a second read.
  """

  use EdgeLinkoutsWeb, :live_view

  require Logger

  alias EdgeLinkouts.{Codec, Cosmos, Display}
  alias EdgeLinkoutsWeb.{Diff, EdgeComponents, Edges}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id} = params, uri, socket) do
    if socket.assigns[:edge_id] == id and socket.assigns[:blob] do
      {:noreply, select_version(socket, params)}
    else
      {:noreply, load(socket, id, params, uri)}
    end
  end

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply,
     load(socket, socket.assigns.edge_id, socket.assigns.params, socket.assigns.permalink)}
  end

  defp load(socket, id, params, uri) do
    socket = assign(socket, edge_id: id, params: params, permalink: uri)

    case Edges.fetch_edge(id) do
      {:ok, stored} ->
        case Codec.decode(stored["b"], Cosmos.dictionary()) do
          {:ok, blob} -> select_version(assign(socket, blob: blob), params)
          {:error, reason} -> assign(socket, view: {:corrupt, human_reason(reason)}, blob: nil)
        end

      {:error, :rate_limited} ->
        assign(socket, view: :rate_limited, blob: nil)

      {:error, :not_found} ->
        # plug_status 404 makes the endpoint render the 404 page with a genuine 404
        # status, so an id typo does not look like success to a crawler or a monitor.
        # (Phoenix re-raises the exception after sending the response; that is its
        # standard behaviour for every rendered error except NoRouteError, whose special
        # handling needs a conn a LiveView does not have.)
        raise EdgeLinkoutsWeb.EdgeNotFound, message: "no edge with id #{inspect(id)} is stored"

      {:error, reason} ->
        # The store itself failed (network, auth): retryable like throttling, but the
        # page must not claim the RU budget was hit. The reason stays in the logs.
        Logger.warning("edge #{inspect(id)} read failed: #{inspect(reason)}")
        assign(socket, view: :store_error, blob: nil)
    end
  end

  defp select_version(socket, params) do
    blob = socket.assigns.blob
    versions = Codec.versions(blob)
    requested = params["version"]

    if is_binary(requested) and requested not in versions do
      assign(socket,
        view: {:corrupt, "the blob does not store a version named #{inspect(requested)}"},
        diff: nil
      )
    else
      key = if is_binary(requested), do: requested, else: Codec.newest(blob)
      render_version(socket, blob, versions, key)
    end
  end

  defp render_version(socket, blob, versions, key) do
    case Codec.resolve(blob, key) do
      {:ok, doc} ->
        config = Display.for_key(key)
        prev_key = previous_version(versions, key)

        assign(socket,
          view: :ok,
          versions: versions,
          key: key,
          doc: doc,
          kg_name: (config && config.display_name) || Codec.kg_name(key),
          sentence: sentence(config, doc, key),
          evidence: evidence(config, doc, key),
          diff: diff(blob, prev_key, doc),
          prev_key: prev_key,
          config: config,
          feedback_url:
            Display.feedback_url(config, socket.assigns.edge_id, socket.assigns.permalink),
          page_title: page_title(config, doc, key, socket.assigns.edge_id)
        )

      {:error, reason} ->
        assign(socket, view: {:corrupt, human_reason(reason)}, diff: nil)
    end
  end

  defp sentence(nil, _doc, _key), do: nil
  defp sentence(config, doc, key), do: Display.edge(config, doc, key)

  defp evidence(nil, _doc, _key), do: []
  defp evidence(config, doc, key), do: Display.evidence(config, doc, key)

  defp page_title(nil, _doc, key, _id), do: "Edge #{Codec.kg_name(key)}"
  defp page_title(config, doc, key, _id), do: Display.title(config, doc, key)

  defp previous_version(versions, key) do
    versions
    |> Enum.split_while(&(&1 != key))
    |> elem(0)
    |> List.last()
  end

  # nil means "the previous version could not be resolved", which the diff panel states
  # explicitly rather than pretending nothing changed.
  defp diff(_blob, nil, _doc), do: nil

  defp diff(blob, prev_key, doc) do
    case Codec.resolve(blob, prev_key) do
      {:ok, prev_doc} -> Diff.diff(prev_doc, doc)
      {:error, _reason} -> nil
    end
  end

  defp human_reason(:invalid_base64), do: "the stored frame is not valid base64"
  defp human_reason(:no_versions), do: "the blob stores no versions"

  defp human_reason({:zstd, detail}) do
    "the stored frame failed to decompress (#{detail})"
  end

  defp human_reason({:json, detail}) do
    "the stored frame is not valid JSON (#{detail})"
  end

  defp human_reason({:schema, found, expected}) do
    "unknown blob schema #{inspect(found)} (expected #{inspect(expected)})"
  end

  defp human_reason({:not_a_blob, keys}),
    do: "the document is not a versioned blob (#{inspect(keys)})"

  defp human_reason({:unknown_version, version, _order}) do
    "the blob does not store a version named #{inspect(version)}"
  end

  defp human_reason({:cycle, version}), do: "the delta chain for #{inspect(version)} is circular"
  defp human_reason({:null_at, path}), do: "a null value at #{path}"
  defp human_reason({:null_at, path, version}), do: "a null value at #{path} (#{version})"

  defp human_reason(other), do: "the blob is malformed (#{inspect(other)})"
end
