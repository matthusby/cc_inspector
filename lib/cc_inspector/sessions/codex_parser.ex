defmodule CcInspector.Sessions.CodexParser do
  @moduledoc """
  Parses local Codex rollout files into the provider-neutral session model.

  Current Codex sessions are append-only JSONL rollouts. Early Codex versions
  used a single JSON object with `session` and `items` keys; those files are
  supported as transcript-only legacy sessions.
  """

  alias CcInspector.Sessions.Summary
  alias CcInspector.Sessions.Turns
  alias CcInspector.Sessions.Turns.{Block, Turn}
  alias CcInspector.Sessions.Usage

  @empty_tokens %{
    input: 0,
    output: 0,
    cache_read: 0,
    cache_creation: 0,
    reasoning: 0
  }

  def parse_file(path) do
    case Path.extname(path) do
      ".json" -> parse_legacy_file(path)
      _ -> parse_rollout_file(path)
    end
  end

  defp parse_rollout_file(path) do
    acc =
      path
      |> File.stream!([:read_ahead])
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, row} -> [row]
          {:error, _} -> []
        end
      end)
      |> Enum.reduce(initial_acc(), &fold_rollout/2)

    build_document(finalize_turn(acc), path)
  rescue
    File.Error -> nil
  end

  defp parse_legacy_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"session" => session, "items" => items}} <- Jason.decode(body) do
      timestamp = parse_ts(session["timestamp"])

      acc =
        Enum.reduce(items, %{initial_acc() | meta: session}, fn item, acc ->
          fold_legacy(item, timestamp, acc)
        end)

      build_document(finalize_turn(acc), path)
    else
      _ -> nil
    end
  end

  defp initial_acc do
    %{
      meta: %{},
      source: nil,
      cwd: nil,
      git_branch: nil,
      version: nil,
      model: nil,
      first_ts: nil,
      last_ts: nil,
      current: nil,
      turns: [],
      assistant_count: 0,
      tool_count: 0,
      total_tokens: @empty_tokens,
      usage: Usage.new()
    }
  end

  defp fold_rollout(%{"type" => "session_meta", "payload" => payload} = row, acc) do
    git = payload["git"] || %{}

    acc
    |> bump_timestamp(row_timestamp(row) || parse_ts(payload["timestamp"]))
    |> Map.put(:meta, payload)
    |> Map.put(:source, normalize_source(payload["source"]))
    |> Map.put(:cwd, payload["cwd"])
    |> Map.put(:git_branch, git["branch"])
    |> Map.put(:version, payload["cli_version"])
  end

  defp fold_rollout(%{"type" => "turn_context", "payload" => payload} = row, acc) do
    acc =
      acc
      |> bump_timestamp(row_timestamp(row))
      |> Map.put(:model, payload["model"] || acc.model)
      |> Map.put(:cwd, payload["cwd"] || acc.cwd)

    update_current(acc, fn turn ->
      %{turn | id: payload["turn_id"] || turn.id, model: payload["model"] || turn.model}
    end)
  end

  defp fold_rollout(
         %{"type" => "event_msg", "payload" => %{"type" => "user_message"} = payload} = row,
         acc
       ) do
    text = legacy_message_text(payload["message"])

    if text == "" do
      bump_timestamp(acc, row_timestamp(row))
    else
      start_turn(acc, text, row_timestamp(row), nil)
    end
  end

  defp fold_rollout(
         %{
           "type" => "response_item",
           "payload" => %{"type" => "message", "role" => "assistant"} = payload
         } = row,
         acc
       ) do
    timestamp = row_timestamp(row)

    blocks =
      payload["content"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "output_text", "text" => text} when is_binary(text) ->
          [%Block{kind: :text, data: %{text: text}, timestamp: timestamp}]

        _ ->
          []
      end)

    acc
    |> bump_timestamp(timestamp)
    |> append_blocks(blocks)
    |> Map.update!(:assistant_count, &(&1 + 1))
  end

  defp fold_rollout(
         %{"type" => "response_item", "payload" => %{"type" => "reasoning"} = payload} = row,
         acc
       ) do
    timestamp = row_timestamp(row)

    text =
      payload["summary"]
      |> List.wrap()
      |> Enum.map_join("\n\n", fn
        %{"text" => text} when is_binary(text) -> text
        _ -> ""
      end)

    encrypted? = is_binary(payload["encrypted_content"])

    blocks =
      if text != "" or encrypted? do
        [%Block{kind: :thinking, data: %{text: empty_to_nil(text)}, timestamp: timestamp}]
      else
        []
      end

    acc |> bump_timestamp(timestamp) |> append_blocks(blocks)
  end

  defp fold_rollout(
         %{"type" => "response_item", "payload" => %{"type" => type} = payload} = row,
         acc
       )
       when type in ["custom_tool_call", "function_call"] do
    timestamp = row_timestamp(row)
    call_id = payload["call_id"] || payload["id"]

    block = %Block{
      kind: :tool_use,
      data: %{
        id: call_id,
        name: payload["name"] || "tool",
        input: decode_json_value(payload["input"] || payload["arguments"]),
        result: nil
      },
      timestamp: timestamp
    }

    acc
    |> bump_timestamp(timestamp)
    |> append_blocks([block])
    |> Map.update!(:tool_count, &(&1 + 1))
  end

  defp fold_rollout(
         %{"type" => "response_item", "payload" => %{"type" => type} = payload} = row,
         acc
       )
       when type in ["custom_tool_call_output", "function_call_output"] do
    timestamp = row_timestamp(row)

    block = %Block{
      kind: :tool_result,
      data: %{
        tool_use_id: payload["call_id"],
        content: payload["output"],
        is_error: payload["is_error"] == true
      },
      timestamp: timestamp
    }

    acc |> bump_timestamp(timestamp) |> append_blocks([block])
  end

  defp fold_rollout(
         %{"type" => "event_msg", "payload" => %{"type" => "token_count"} = payload} = row,
         acc
       ) do
    info = payload["info"] || %{}
    last = token_usage(info["last_token_usage"])
    total = token_usage(info["total_token_usage"])
    timestamp = row_timestamp(row)

    acc =
      acc
      |> bump_timestamp(timestamp)
      |> Map.put(:total_tokens, if(total == @empty_tokens, do: acc.total_tokens, else: total))

    if last == @empty_tokens do
      acc
    else
      # A turn emits one token_count row per model request, so these accumulate.
      # Assigning `last` here instead of adding it undercounted every turn by
      # however many requests it took, which for long turns is a large factor.
      acc
      |> Map.put(:usage, Usage.add(acc.usage, timestamp, last))
      |> update_current(fn turn -> %{turn | tokens: Usage.sum(turn.tokens, last)} end)
    end
  end

  defp fold_rollout(row, acc), do: bump_timestamp(acc, row_timestamp(row))

  defp fold_legacy(%{"type" => "message", "role" => "user"} = item, timestamp, acc) do
    text = legacy_message_text(item["content"])
    if text == "", do: acc, else: start_turn(acc, text, timestamp, nil)
  end

  defp fold_legacy(%{"type" => "message", "role" => "assistant"} = item, timestamp, acc) do
    text = legacy_message_text(item["content"])

    blocks =
      if text == "" do
        []
      else
        [%Block{kind: :text, data: %{text: text}, timestamp: timestamp}]
      end

    acc
    |> bump_timestamp(timestamp)
    |> append_blocks(blocks)
    |> Map.update!(:assistant_count, &(&1 + 1))
  end

  defp fold_legacy(_, _, acc), do: acc

  defp start_turn(acc, text, timestamp, id) do
    acc = finalize_turn(acc)

    turn = %Turn{
      id: id || "codex-turn-#{length(acc.turns) + 1}",
      index: nil,
      started_at: timestamp,
      ended_at: timestamp,
      user_text: text,
      user_kind: :prompt,
      blocks: [],
      tokens: @empty_tokens,
      cost: nil,
      model: acc.model
    }

    acc |> bump_timestamp(timestamp) |> Map.put(:current, turn)
  end

  defp finalize_turn(%{current: nil} = acc), do: acc

  defp finalize_turn(acc) do
    %{acc | current: nil, turns: [acc.current | acc.turns]}
  end

  defp append_blocks(acc, []), do: acc

  defp append_blocks(acc, blocks) do
    update_current(acc, fn turn ->
      last_timestamp = blocks |> List.last() |> then(& &1.timestamp)

      %{
        turn
        | blocks: turn.blocks ++ blocks,
          ended_at: latest(turn.ended_at, last_timestamp)
      }
    end)
  end

  defp update_current(%{current: nil} = acc, _fun), do: acc
  defp update_current(acc, fun), do: %{acc | current: fun.(acc.current)}

  defp build_document(acc, path) do
    turns =
      acc.turns
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, index} -> %{turn | index: index} end)
      |> Turns.pair_tool_results()

    session_id = acc.meta["id"] || acc.meta["session_id"] || legacy_id(acc.meta, path)
    cwd = acc.cwd || "Codex legacy sessions"
    tokens = total_tokens(acc.total_tokens, turns)

    summary = %Summary{
      provider: :codex,
      session_id: session_id,
      path: path,
      project_cwd: cwd,
      project_slug: Path.basename(cwd),
      git_branch: acc.git_branch,
      started_at: acc.first_ts,
      last_activity_at: acc.last_ts,
      duration_ms: ms_between(acc.first_ts, acc.last_ts),
      model: acc.model,
      version: acc.version,
      user_message_count: length(turns),
      assistant_message_count: acc.assistant_count,
      tool_call_count: acc.tool_count,
      turn_count: length(turns),
      tokens: tokens,
      cost: nil,
      first_prompt_preview: turns |> List.first() |> prompt_preview(),
      ai_title: nil,
      usage: acc.usage
    }

    %{summary: summary, turns: turns, source: acc.source}
  end

  defp total_tokens(@empty_tokens, turns) do
    Enum.reduce(turns, @empty_tokens, fn turn, total ->
      Map.new(@empty_tokens, fn {key, _} -> {key, total[key] + turn.tokens[key]} end)
    end)
  end

  defp total_tokens(tokens, _turns), do: tokens

  defp token_usage(nil), do: @empty_tokens

  defp token_usage(usage) do
    %{
      input: usage["input_tokens"] || 0,
      output: usage["output_tokens"] || 0,
      cache_read: usage["cached_input_tokens"] || 0,
      cache_creation: 0,
      reasoning: usage["reasoning_output_tokens"] || 0
    }
  end

  defp row_timestamp(%{"timestamp" => timestamp}), do: parse_ts(timestamp)
  defp row_timestamp(_), do: nil

  defp bump_timestamp(acc, nil), do: acc

  defp bump_timestamp(acc, timestamp) do
    %{
      acc
      | first_ts: earliest(acc.first_ts, timestamp),
        last_ts: latest(acc.last_ts, timestamp)
    }
  end

  defp legacy_message_text(content) when is_binary(content), do: String.trim(content)

  defp legacy_message_text(content) do
    content
    |> List.wrap()
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> String.trim()
  end

  defp decode_json_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp decode_json_value(value), do: value || %{}

  defp normalize_source(source) when is_binary(source), do: String.downcase(source)
  defp normalize_source(%{"subagent" => _}), do: "subagent"
  defp normalize_source(_), do: nil

  defp legacy_id(%{"id" => id}, _path) when is_binary(id), do: id
  defp legacy_id(_, path), do: path |> Path.basename() |> Path.rootname()

  defp prompt_preview(nil), do: nil

  defp prompt_preview(%Turn{user_text: text}) do
    text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 140)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(text), do: text

  defp parse_ts(nil), do: nil

  defp parse_ts(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp earliest(nil, timestamp), do: timestamp
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
  defp latest(nil, timestamp), do: timestamp
  defp latest(timestamp, nil), do: timestamp
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp ms_between(nil, _), do: nil
  defp ms_between(_, nil), do: nil
  defp ms_between(a, b), do: DateTime.diff(b, a, :millisecond)
end
