defmodule CcInspector.Sessions.Cache do
  @moduledoc """
  ETS-backed cache of parsed session events keyed by file path.

  Entries are invalidated automatically when the file's mtime/size change
  (cheap stat on every read), and explicitly by the watcher on filesystem
  events. The JSONL files are append-only, so re-parsing is safe and idempotent.
  """

  use GenServer

  alias CcInspector.Sessions.{CodexParser, Parser, Summary, Turns}

  @table __MODULE__

  # Bump whenever the shape of a cached value changes. Entries are plain terms,
  # so a struct that gains a field leaves already-cached copies without it —
  # which raises at the read site rather than anywhere near the cause. Stamping
  # the version makes stale entries simply miss and reload. Matters in dev,
  # where code reloads but the table survives.
  @version 2

  ## Client

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def list_summaries(dir) do
    dir
    |> session_paths()
    |> Enum.map(&summary_for_path/1)
    |> Enum.reject(&is_nil/1)
  end

  def summary(session_id, dir) do
    case find_path(session_id, dir) do
      nil -> nil
      path -> summary_for_path(path)
    end
  end

  def turns(session_id, dir) do
    case find_path(session_id, dir) do
      nil -> nil
      path -> path |> events_for_path() |> Turns.from_events()
    end
  end

  def codex_document(path),
    do: cached_for_path({:codex, path}, path, fn -> CodexParser.parse_file(path) end)

  def invalidate(path) do
    :ets.delete(@table, path)
    :ets.delete(@table, {:codex, path})
    :ets.delete(@table, {:summary, path})
  end

  @doc """
  Memoises a provider-wide value that isn't derived from a single file, so it
  has no mtime to validate against. Invalidated explicitly by the watcher.
  """
  def fetch_provider(key, loader) do
    cache_key = {:provider, key}

    case :ets.lookup(@table, cache_key) do
      [{^cache_key, @version, value}] ->
        value

      _ ->
        value = loader.()
        :ets.insert(@table, {cache_key, @version, value})
        value
    end
  end

  def invalidate_provider(key), do: :ets.delete(@table, {:provider, key})

  ## Server

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internals

  defp session_paths(dir) do
    Path.wildcard(Path.join([dir, "*", "*.jsonl"]))
  end

  defp find_path(session_id, dir) do
    Path.wildcard(Path.join([dir, "*", session_id <> ".jsonl"])) |> List.first()
  end

  # Cached in its own right, not just derived from the cached events. The index
  # only ever wants summaries, and re-folding every event on each warm read cost
  # more than the rest of the scan combined.
  defp summary_for_path(path) do
    cached_for_path({:summary, path}, path, fn ->
      case events_for_path(path) do
        nil -> nil
        [] -> nil
        events -> Summary.from_events(events, path)
      end
    end)
  end

  defp events_for_path(path) do
    cached_for_path(path, path, fn -> Parser.parse_file(path) end)
  end

  defp cached_for_path(key, path, loader) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        case :ets.lookup(@table, key) do
          [{^key, @version, ^mtime, ^size, value}] ->
            value

          _ ->
            value = loader.()
            :ets.insert(@table, {key, @version, mtime, size, value})
            value
        end

      _ ->
        nil
    end
  end
end
