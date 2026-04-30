defmodule CcInspector.Sessions.Watcher do
  @moduledoc """
  Watches the Claude Code projects directory for new/modified session JSONL
  files and broadcasts events on the `sessions` and `session:<id>` PubSub topics.

  Only top-level session files (`<dir>/<slug>/<id>.jsonl`) are surfaced —
  sub-agent transcripts under `<id>/subagents/` and tool-result spillover
  files under `<id>/tool-results/` are ignored.
  """

  use GenServer
  require Logger

  alias CcInspector.Sessions.Cache

  @pubsub CcInspector.PubSub

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    dir = Application.fetch_env!(:cc_inspector, :claude_projects_dir)
    File.mkdir_p!(dir)

    {:ok, fs_pid} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(fs_pid)

    {:ok, %{dir: dir, fs_pid: fs_pid}}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    if main_session_file?(path, state.dir) do
      handle_session_event(path, events)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  defp handle_session_event(path, events) do
    id = session_id_from_path(path)

    cond do
      :removed in events or :deleted in events ->
        Cache.invalidate(path)
        broadcast("sessions", {:session_removed, id})

      :created in events and not (:modified in events or :renamed in events) ->
        Cache.invalidate(path)
        broadcast("sessions", {:session_created, id})

      true ->
        Cache.invalidate(path)
        broadcast("sessions", {:session_updated, id})
        broadcast("session:" <> id, {:session_updated, id})
    end
  end

  defp main_session_file?(path, dir) do
    rel = Path.relative_to(path, dir)

    case Path.split(rel) do
      [_slug, file] -> String.ends_with?(file, ".jsonl")
      _ -> false
    end
  end

  defp session_id_from_path(path), do: Path.basename(path, ".jsonl")

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(@pubsub, topic, msg)
end
