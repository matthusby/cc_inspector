defmodule CcInspector.Sessions.OpenCodeParser do
  @moduledoc false

  alias CcInspector.Sessions.Summary
  alias CcInspector.Sessions.Turns.{Block, Turn}

  @empty_tokens %{
    input: 0,
    output: 0,
    cache_read: 0,
    cache_creation: 0,
    reasoning: 0
  }

  def summary_from_row(row) do
    cwd = row["directory"] || "OpenCode"
    started_at = from_unix_ms(row["time_created"])
    updated_at = from_unix_ms(row["time_updated"])

    %Summary{
      provider: :opencode,
      session_id: row["id"],
      path: nil,
      project_cwd: cwd,
      project_slug: Path.basename(cwd),
      git_branch: nil,
      started_at: started_at,
      last_activity_at: updated_at,
      duration_ms: ms_between(started_at, updated_at),
      model: row["model"],
      version: row["version"],
      user_message_count: row["user_message_count"] || 0,
      assistant_message_count: row["assistant_message_count"] || 0,
      tool_call_count: row["tool_call_count"] || 0,
      turn_count: row["user_message_count"] || 0,
      tokens: %{
        input: row["tokens_input"] || 0,
        output: row["tokens_output"] || 0,
        cache_read: row["tokens_cache_read"] || 0,
        cache_creation: row["tokens_cache_write"] || 0,
        reasoning: row["tokens_reasoning"] || 0
      },
      cost: row["cost"],
      first_prompt_preview: preview(row["first_prompt"]),
      ai_title: row["title"]
    }
  end

  def turns_from_export(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.reduce({[], nil}, &fold_message/2)
    |> finalize_turns()
  end

  def turns_from_export(_), do: []

  def turns_from_rows(rows) when is_list(rows) do
    messages =
      Enum.flat_map(rows, fn row ->
        with {:ok, info} <- Jason.decode(row["info"] || "{}"),
             {:ok, parts} <- Jason.decode(row["parts"] || "[]") do
          [%{"info" => info, "parts" => parts}]
        else
          _ -> []
        end
      end)

    turns_from_export(%{"messages" => messages})
  end

  def turns_from_rows(_), do: []

  defp fold_message(%{"info" => %{"role" => "user"} = info, "parts" => parts}, {turns, current}) do
    turns = if current, do: [current | turns], else: turns
    text = user_text(parts)
    timestamp = message_time(info, "created")

    turn = %Turn{
      id: info["id"] || "opencode-turn-#{length(turns) + 1}",
      index: nil,
      started_at: timestamp,
      ended_at: timestamp,
      user_text: text,
      user_kind: :prompt,
      blocks: [],
      tokens: @empty_tokens,
      cost: 0.0,
      model: model_name(info)
    }

    {turns, turn}
  end

  defp fold_message(
         %{"info" => %{"role" => "assistant"} = info, "parts" => parts},
         {turns, %Turn{} = current}
       ) do
    timestamp = message_time(info, "completed") || message_time(info, "created")
    blocks = Enum.flat_map(parts, &part_block(&1, timestamp))

    current = %{
      current
      | ended_at: latest(current.ended_at, timestamp),
        blocks: current.blocks ++ blocks,
        tokens: add_tokens(current.tokens, info["tokens"]),
        cost: (current.cost || 0.0) + (info["cost"] || 0.0),
        model: model_name(info) || current.model
    }

    {turns, current}
  end

  defp fold_message(_, state), do: state

  defp finalize_turns({turns, current}) do
    turns = if current, do: [current | turns], else: turns

    turns
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} -> %{turn | index: index} end)
  end

  defp part_block(%{"type" => "text", "text" => text}, timestamp) when is_binary(text) do
    [%Block{kind: :text, data: %{text: text}, timestamp: timestamp}]
  end

  defp part_block(%{"type" => "reasoning", "text" => text}, timestamp) do
    [%Block{kind: :thinking, data: %{text: empty_to_nil(text)}, timestamp: timestamp}]
  end

  defp part_block(%{"type" => "tool"} = part, timestamp) do
    state = part["state"] || %{}
    status = state["status"]

    result =
      if Map.has_key?(state, "output") do
        %{
          content: state["output"],
          is_error: status in ["error", "failed"]
        }
      end

    [
      %Block{
        kind: :tool_use,
        data: %{
          id: part["callID"] || part["id"],
          name: part["tool"] || "tool",
          input: state["input"] || %{},
          result: result
        },
        timestamp: timestamp
      }
    ]
  end

  defp part_block(_, _timestamp), do: []

  defp user_text(parts) do
    parts
    |> List.wrap()
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "file", "filename" => name} when is_binary(name) -> "[file: #{name}]"
      _ -> ""
    end)
    |> String.trim()
  end

  defp add_tokens(tokens, nil), do: tokens

  defp add_tokens(tokens, usage) do
    cache = usage["cache"] || %{}

    %{
      input: tokens.input + (usage["input"] || 0),
      output: tokens.output + (usage["output"] || 0),
      cache_read: tokens.cache_read + (cache["read"] || 0),
      cache_creation: tokens.cache_creation + (cache["write"] || 0),
      reasoning: tokens.reasoning + (usage["reasoning"] || 0)
    }
  end

  defp model_name(info) do
    case {info["providerID"], info["modelID"]} do
      {provider, model} when is_binary(provider) and is_binary(model) -> "#{provider}/#{model}"
      {_, model} when is_binary(model) -> model
      _ -> nil
    end
  end

  defp message_time(info, key) do
    info |> Map.get("time", %{}) |> Map.get(key) |> from_unix_ms()
  end

  defp from_unix_ms(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp from_unix_ms(_), do: nil

  defp preview(nil), do: nil

  defp preview(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 140)
  end

  defp empty_to_nil(text) when text in [nil, ""], do: nil
  defp empty_to_nil(text), do: text

  defp latest(nil, timestamp), do: timestamp
  defp latest(timestamp, nil), do: timestamp
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp ms_between(nil, _), do: nil
  defp ms_between(_, nil), do: nil
  defp ms_between(a, b), do: DateTime.diff(b, a, :millisecond)
end
