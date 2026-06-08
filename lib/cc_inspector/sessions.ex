defmodule CcInspector.Sessions do
  @moduledoc """
  Read-only view of Claude Code session JSONL files.

  Sessions live at `<claude_projects_dir>/<project-slug>/<session-id>.jsonl`.
  Sub-agent transcripts under `<...>/<session-id>/subagents/agent-*.jsonl`
  are intentionally not surfaced as top-level sessions.
  """

  alias CcInspector.Sessions.Cache

  # Sessions whose JSONL has no timestamped entries have a nil
  # last_activity_at, which DateTime.compare/2 can't sort. Treat them as the
  # epoch so they sort to the bottom instead of crashing.
  @epoch ~U[1970-01-01 00:00:00Z]

  def list_summaries do
    Cache.list_summaries(claude_dir())
    |> Enum.sort_by(&(&1.last_activity_at || @epoch), {:desc, DateTime})
  end

  def get_summary(session_id), do: Cache.summary(session_id, claude_dir())

  def get_turns(session_id), do: Cache.turns(session_id, claude_dir())

  def subscribe, do: Phoenix.PubSub.subscribe(CcInspector.PubSub, "sessions")

  def subscribe(session_id) when is_binary(session_id),
    do: Phoenix.PubSub.subscribe(CcInspector.PubSub, "session:" <> session_id)

  def claude_dir, do: Application.fetch_env!(:cc_inspector, :claude_projects_dir)
end
