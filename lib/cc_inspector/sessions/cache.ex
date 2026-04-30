defmodule CcInspector.Sessions.Cache do
  @moduledoc """
  ETS-backed cache of parsed session events keyed by file path.

  Entries are invalidated automatically when the file's mtime/size change
  (cheap stat on every read), and explicitly by the watcher on filesystem
  events. The JSONL files are append-only, so re-parsing is safe and idempotent.
  """

  use GenServer

  alias CcInspector.Sessions.{Parser, Summary, Turns}

  @table __MODULE__

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

  def invalidate(path), do: :ets.delete(@table, path)

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

  defp summary_for_path(path) do
    case events_for_path(path) do
      [] -> nil
      events -> Summary.from_events(events, path)
    end
  end

  defp events_for_path(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        case :ets.lookup(@table, path) do
          [{^path, ^mtime, ^size, events}] ->
            events

          _ ->
            events = Parser.parse_file(path)
            :ets.insert(@table, {path, mtime, size, events})
            events
        end

      _ ->
        []
    end
  end
end
