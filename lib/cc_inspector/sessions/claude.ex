defmodule CcInspector.Sessions.Claude do
  @moduledoc false

  alias CcInspector.Sessions.Cache

  def list_summaries do
    Cache.list_summaries(projects_dir())
  end

  def get_summary(session_id), do: Cache.summary(session_id, projects_dir())
  def get_turns(session_id), do: Cache.turns(session_id, projects_dir())

  def projects_dir do
    Application.fetch_env!(:cc_inspector, :claude_projects_dir)
  end

  def session_path?(path) do
    relative = Path.relative_to(path, projects_dir())

    case Path.split(relative) do
      [_project, file] -> String.ends_with?(file, ".jsonl")
      _ -> false
    end
  end

  def session_id_from_path(path), do: Path.basename(path, ".jsonl")
end
