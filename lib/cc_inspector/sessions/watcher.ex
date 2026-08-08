defmodule CcInspector.Sessions.Watcher do
  @moduledoc """
  Watches local Claude Code and Codex transcripts plus the OpenCode database,
  then broadcasts provider-aware invalidation events.
  """

  use GenServer
  require Logger

  alias CcInspector.Sessions
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

    state = %{
      dirs: dirs,
      fs_pid: fs_pid,
      opencode_timer: nil,
      opencode_task: nil,
      opencode_stale?: false
    }

    # Warm the first snapshot here rather than on the first read, so no page load
    # ever waits on the CLI.
    {:ok, start_opencode_refresh(state)}
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
    {:noreply, start_opencode_refresh(%{state | opencode_timer: nil})}
  end

  # A refresh finished. Announce it only on success — a failed run left the
  # previous snapshot in place, so there is nothing new for the index to show.
  def handle_info({ref, result}, %{opencode_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    if result == :ok do
      broadcast("sessions", {:provider_changed, :opencode})
      broadcast("provider:opencode", {:provider_changed, :opencode})
    end

    state = %{state | opencode_task: nil}

    if state.opencode_stale? do
      {:noreply, start_opencode_refresh(%{state | opencode_stale?: false})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{opencode_task: %Task{ref: ref}} = state
      ) do
    {:noreply, %{state | opencode_task: nil, opencode_stale?: false}}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_opencode_refresh(%{opencode_timer: nil} = state) do
    %{state | opencode_timer: Process.send_after(self(), :opencode_changed, 1_000)}
  end

  defp schedule_opencode_refresh(state), do: state

  # One refresh at a time. Changes that land mid-flight set a flag instead of
  # stacking up CLI invocations, since each one costs about a second.
  defp start_opencode_refresh(%{opencode_task: nil} = state) do
    if :opencode in Sessions.enabled_providers() do
      task = Task.Supervisor.async_nolink(CcInspector.TaskSupervisor, &OpenCode.refresh/0)
      %{state | opencode_task: task}
    else
      state
    end
  end

  defp start_opencode_refresh(state), do: %{state | opencode_stale?: true}

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
