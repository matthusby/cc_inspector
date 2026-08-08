defmodule CcInspector.Sessions.Watcher do
  @moduledoc """
  Watches local Claude Code and Codex transcripts plus the OpenCode database,
  then broadcasts provider-aware invalidation events.
  """

  use GenServer
  require Logger

  alias CcInspector.Sessions.{Cache, Claude, Codex, OpenCode}

  @pubsub CcInspector.PubSub

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    File.mkdir_p!(Claude.projects_dir())

    dirs =
      [Claude.projects_dir(), Codex.home(), OpenCode.data_dir()]
      |> Enum.filter(&File.dir?/1)
      |> Enum.uniq()

    {:ok, fs_pid} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(fs_pid)

    {:ok, %{dirs: dirs, fs_pid: fs_pid, opencode_timer: nil}}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    state =
      cond do
        Claude.session_path?(path) ->
          handle_session_event(:claude, Claude.session_id_from_path(path), path, events)
          state

        Codex.session_path?(path) ->
          handle_session_event(:codex, Codex.session_id_from_path(path), path, events)
          state

        OpenCode.database_file?(path) ->
          schedule_opencode_refresh(state)

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:opencode_changed, state) do
    Cache.invalidate_provider(:opencode_summaries)
    Cache.invalidate_provider(:opencode_usage)
    broadcast("sessions", {:provider_changed, :opencode})
    broadcast("provider:opencode", {:provider_changed, :opencode})
    {:noreply, %{state | opencode_timer: nil}}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  defp schedule_opencode_refresh(%{opencode_timer: nil} = state) do
    %{state | opencode_timer: Process.send_after(self(), :opencode_changed, 1_000)}
  end

  defp schedule_opencode_refresh(state), do: state

  defp handle_session_event(provider, id, path, events) do
    Cache.invalidate(path)

    action =
      cond do
        :removed in events or :deleted in events -> :removed
        :created in events and not (:modified in events or :renamed in events) -> :created
        true -> :updated
      end

    message = {:session_changed, provider, id, action}
    broadcast("sessions", message)
    broadcast("session:#{provider}:#{id}", message)
  end

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(@pubsub, topic, msg)
end
