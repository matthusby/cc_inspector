defmodule CcInspector.Sessions.Summary do
  @moduledoc """
  Folds a session's events into a high-level summary for the index page.
  """

  alias CcInspector.Sessions.Parser.Event

  defstruct [
    :provider,
    :session_id,
    :path,
    :project_cwd,
    :project_slug,
    :git_branch,
    :started_at,
    :last_activity_at,
    :duration_ms,
    :model,
    :version,
    :user_message_count,
    :assistant_message_count,
    :tool_call_count,
    :turn_count,
    :tokens,
    :cost,
    :first_prompt_preview,
    :ai_title
  ]

  def from_events([], _path), do: nil

  def from_events(events, path) do
    project_slug = path |> Path.dirname() |> Path.basename()
    session_id = Path.basename(path, ".jsonl")

    init = %{
      first_ts: nil,
      last_ts: nil,
      cwd: nil,
      git_branch: nil,
      version: nil,
      model: nil,
      user_count: 0,
      assistant_count: 0,
      tool_count: 0,
      turn_count: 0,
      tokens: %{input: 0, output: 0, cache_read: 0, cache_creation: 0},
      first_prompt: nil,
      ai_title: nil,
      seen_message_ids: MapSet.new()
    }

    acc = Enum.reduce(events, init, &fold/2)

    %__MODULE__{
      provider: :claude,
      session_id: session_id,
      path: path,
      project_cwd: acc.cwd || slug_to_cwd(project_slug),
      project_slug: project_slug,
      git_branch: acc.git_branch,
      started_at: acc.first_ts,
      last_activity_at: acc.last_ts,
      duration_ms: ms_between(acc.first_ts, acc.last_ts),
      model: acc.model,
      version: acc.version,
      user_message_count: acc.user_count,
      assistant_message_count: acc.assistant_count,
      tool_call_count: acc.tool_count,
      turn_count: acc.turn_count,
      tokens: Map.put(acc.tokens, :reasoning, 0),
      cost: nil,
      first_prompt_preview: acc.first_prompt,
      ai_title: acc.ai_title
    }
  end

  defp fold(%Event{} = ev, acc) do
    acc
    |> bump_timestamps(ev.timestamp)
    |> capture_project(ev)
    |> capture_model(ev)
    |> capture_ai_title(ev)
    |> count_event(ev)
    |> add_usage(ev)
    |> capture_first_prompt(ev)
  end

  defp bump_timestamps(acc, nil), do: acc

  defp bump_timestamps(acc, ts) do
    %{
      acc
      | first_ts: earliest(acc.first_ts, ts),
        last_ts: latest(acc.last_ts, ts)
    }
  end

  defp capture_project(acc, %Event{cwd: cwd, git_branch: branch, version: version}) do
    %{
      acc
      | cwd: acc.cwd || cwd,
        git_branch: acc.git_branch || branch,
        version: version || acc.version
    }
  end

  defp capture_model(acc, %Event{type: :assistant, model: model}) when is_binary(model),
    do: %{acc | model: model}

  defp capture_model(acc, _), do: acc

  defp capture_ai_title(acc, %Event{type: :ai_title, ai_title: title}) when is_binary(title),
    do: %{acc | ai_title: title}

  defp capture_ai_title(acc, _), do: acc

  defp count_event(acc, %Event{type: :user, is_meta: false} = ev) do
    cond do
      user_started_turn?(ev) ->
        %{acc | user_count: acc.user_count + 1, turn_count: acc.turn_count + 1}

      true ->
        acc
    end
  end

  defp count_event(acc, %Event{type: :assistant, content: blocks}) when is_list(blocks) do
    tool_uses = Enum.count(blocks, &block_type?(&1, "tool_use"))
    %{acc | assistant_count: acc.assistant_count + 1, tool_count: acc.tool_count + tool_uses}
  end

  defp count_event(acc, _), do: acc

  defp add_usage(acc, %Event{type: :assistant, usage: %{} = usage, message_id: id})
       when is_binary(id) do
    if MapSet.member?(acc.seen_message_ids, id) do
      acc
    else
      %{
        acc
        | seen_message_ids: MapSet.put(acc.seen_message_ids, id),
          tokens: %{
            input: acc.tokens.input + usage.input,
            output: acc.tokens.output + usage.output,
            cache_read: acc.tokens.cache_read + usage.cache_read,
            cache_creation: acc.tokens.cache_creation + usage.cache_creation
          }
      }
    end
  end

  defp add_usage(acc, _), do: acc

  defp capture_first_prompt(%{first_prompt: nil} = acc, %Event{type: :user, is_meta: false} = ev) do
    case prompt_text(ev) do
      nil -> acc
      text -> if skip_for_preview?(text), do: acc, else: %{acc | first_prompt: preview(text)}
    end
  end

  defp capture_first_prompt(acc, _), do: acc

  defp skip_for_preview?(text) do
    slash_caveat?(text) or slash_command?(text)
  end

  defp slash_command?(text), do: String.starts_with?(text, "<command-name>")

  defp user_started_turn?(%Event{content: content}) do
    case content do
      bin when is_binary(bin) -> not slash_caveat?(bin)
      list when is_list(list) -> not Enum.any?(list, &block_type?(&1, "tool_result"))
      _ -> false
    end
  end

  defp prompt_text(%Event{content: content}) do
    case content do
      bin when is_binary(bin) ->
        bin

      list when is_list(list) ->
        list
        |> Enum.find_value(fn
          %{"type" => "text", "text" => t} when is_binary(t) -> t
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp slash_caveat?(text), do: String.starts_with?(text, "<local-command-caveat>")

  defp block_type?(%{"type" => type}, type), do: true
  defp block_type?(_, _), do: false

  defp earliest(nil, ts), do: ts
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp latest(nil, ts), do: ts
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp ms_between(nil, _), do: nil
  defp ms_between(_, nil), do: nil
  defp ms_between(a, b), do: DateTime.diff(b, a, :millisecond)

  defp slug_to_cwd("-" <> rest), do: "/" <> String.replace(rest, "-", "/")
  defp slug_to_cwd(other), do: other

  defp preview(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end
end
