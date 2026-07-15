defmodule CcInspector.Sessions.Codex do
  @moduledoc false

  alias CcInspector.Sessions.Cache

  @epoch ~U[1970-01-01 00:00:00Z]

  def list_summaries do
    titles = thread_titles()

    top_level_documents()
    |> Enum.map(fn document ->
      title = Map.get(titles, document.summary.session_id)
      %{document.summary | ai_title: title}
    end)
    |> Enum.uniq_by(& &1.session_id)
  end

  def get_summary(session_id) do
    Enum.find(list_summaries(), &(&1.session_id == session_id))
  end

  def get_turns(session_id) do
    top_level_documents()
    |> Enum.find_value(fn document ->
      if document.summary.session_id == session_id, do: document.turns
    end)
  end

  def home do
    Application.fetch_env!(:cc_inspector, :codex_home)
  end

  def session_path?(path) do
    relative = Path.relative_to(path, home())

    case Path.split(relative) do
      ["sessions" | _] -> Path.extname(path) in [".json", ".jsonl"]
      ["archived_sessions", file] -> String.ends_with?(file, ".jsonl")
      _ -> false
    end
  end

  def session_id_from_path(path) do
    basename = path |> Path.basename() |> Path.rootname()

    case Regex.run(~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/, basename) do
      [_, id] -> id
      _ -> basename
    end
  end

  defp documents do
    session_paths()
    |> Task.async_stream(&Cache.codex_document/1,
      ordered: false,
      timeout: :infinity,
      max_concurrency: max(System.schedulers_online(), 2)
    )
    |> Enum.flat_map(fn
      {:ok, document} -> [document]
      _ -> []
    end)
  end

  defp top_level_documents do
    documents()
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1.source == "subagent"))
    |> Enum.sort_by(&(&1.summary.last_activity_at || @epoch), {:desc, DateTime})
  end

  defp session_paths do
    current_jsonl = Path.wildcard(Path.join([home(), "sessions", "**", "*.jsonl"]))
    legacy_json = Path.wildcard(Path.join([home(), "sessions", "*.json"]))
    archived = Path.wildcard(Path.join([home(), "archived_sessions", "*.jsonl"]))

    current_jsonl ++ legacy_json ++ archived
  end

  defp thread_titles do
    path = Path.join(home(), "session_index.jsonl")

    if File.regular?(path) do
      path
      |> File.stream!([:read_ahead])
      |> Enum.reduce(%{}, fn line, titles ->
        case Jason.decode(line) do
          {:ok, %{"id" => id, "thread_name" => title}}
          when is_binary(id) and is_binary(title) ->
            Map.put(titles, id, title)

          _ ->
            titles
        end
      end)
    else
      %{}
    end
  end
end
