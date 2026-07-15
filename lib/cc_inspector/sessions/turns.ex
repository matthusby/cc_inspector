defmodule CcInspector.Sessions.Turns do
  @moduledoc """
  Folds a session's events into a turn-by-turn timeline for the detail page.

  A turn starts when the user inputs something (typed text or a slash command)
  and contains the assistant's cascade of thinking, text, tool calls, and the
  tool results that come back from the user channel until the next user input.
  """

  alias CcInspector.Sessions.Parser.Event

  defmodule Turn do
    @moduledoc false
    defstruct [
      :id,
      :index,
      :started_at,
      :ended_at,
      :user_text,
      :user_kind,
      :blocks,
      :tokens,
      :cost,
      :model
    ]
  end

  defmodule Block do
    @moduledoc false
    defstruct [:kind, :data, :timestamp]
  end

  def from_events(events) do
    events
    |> Enum.reject(&skip?/1)
    |> Enum.reduce({[], MapSet.new()}, &fold/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, idx} -> %{turn | index: idx} end)
    |> attach_tool_results()
  end

  defp skip?(%Event{type: :file_history}), do: true
  defp skip?(%Event{type: :attachment}), do: true
  defp skip?(%Event{type: :system}), do: true
  defp skip?(%Event{type: :permission_mode}), do: true
  defp skip?(%Event{type: :queue_operation}), do: true
  defp skip?(%Event{type: :last_prompt}), do: true
  defp skip?(%Event{type: :ai_title}), do: true
  defp skip?(%Event{type: :unknown}), do: true
  defp skip?(%Event{type: {:other, _}}), do: true
  defp skip?(%Event{is_meta: true}), do: true
  defp skip?(_), do: false

  # New user-initiated turn
  defp fold(%Event{type: :user} = ev, {turns, seen_msgs}) do
    if user_started_turn?(ev) do
      {[start_turn(ev) | turns], seen_msgs}
    else
      # tool_result delivery — append to current turn's blocks
      {append_tool_results(turns, ev), seen_msgs}
    end
  end

  defp fold(%Event{type: :assistant} = ev, {turns, seen_msgs}) do
    case turns do
      [] ->
        # orphan assistant before any user prompt — skip
        {turns, seen_msgs}

      [current | rest] ->
        {updated, seen_msgs} = append_assistant(current, ev, seen_msgs)
        {[updated | rest], seen_msgs}
    end
  end

  defp fold(_, acc), do: acc

  defp start_turn(%Event{} = ev) do
    {kind, text} = classify_user_input(ev.content)

    %Turn{
      id: ev.prompt_id || ev.uuid,
      index: nil,
      started_at: ev.timestamp,
      ended_at: ev.timestamp,
      user_text: text,
      user_kind: kind,
      blocks: [],
      tokens: %{input: 0, output: 0, cache_read: 0, cache_creation: 0, reasoning: 0},
      cost: nil,
      model: nil
    }
  end

  defp append_assistant(%Turn{} = turn, %Event{} = ev, seen_msgs) do
    new_blocks =
      (ev.content || [])
      |> List.wrap()
      |> Enum.map(&assistant_block(&1, ev.timestamp))

    {tokens, seen_msgs} = maybe_add_usage(turn.tokens, ev, seen_msgs)

    {%{
       turn
       | blocks: turn.blocks ++ new_blocks,
         ended_at: latest(turn.ended_at, ev.timestamp),
         tokens: tokens,
         model: ev.model || turn.model
     }, seen_msgs}
  end

  defp assistant_block(%{"type" => "text", "text" => text}, ts),
    do: %Block{kind: :text, data: %{text: text}, timestamp: ts}

  defp assistant_block(%{"type" => "thinking", "thinking" => thought}, ts),
    do: %Block{kind: :thinking, data: %{text: thought}, timestamp: ts}

  defp assistant_block(%{"type" => "tool_use"} = block, ts),
    do: %Block{
      kind: :tool_use,
      data: %{
        id: block["id"],
        name: block["name"],
        input: block["input"]
      },
      timestamp: ts
    }

  defp assistant_block(other, ts),
    do: %Block{kind: :unknown, data: other, timestamp: ts}

  defp append_tool_results([], _), do: []

  defp append_tool_results([current | rest], %Event{content: content, timestamp: ts})
       when is_list(content) do
    new_blocks =
      content
      |> Enum.filter(&match?(%{"type" => "tool_result"}, &1))
      |> Enum.map(fn block ->
        %Block{
          kind: :tool_result,
          data: %{
            tool_use_id: block["tool_use_id"],
            content: block["content"],
            is_error: block["is_error"] == true
          },
          timestamp: ts
        }
      end)

    [
      %{current | blocks: current.blocks ++ new_blocks, ended_at: latest(current.ended_at, ts)}
      | rest
    ]
  end

  defp append_tool_results(turns, _), do: turns

  defp maybe_add_usage(tokens, %Event{usage: nil}, seen), do: {tokens, seen}

  defp maybe_add_usage(tokens, %Event{usage: usage, message_id: id}, seen) when is_binary(id) do
    if MapSet.member?(seen, id) do
      {tokens, seen}
    else
      {%{
         input: tokens.input + usage.input,
         output: tokens.output + usage.output,
         cache_read: tokens.cache_read + usage.cache_read,
         cache_creation: tokens.cache_creation + usage.cache_creation,
         reasoning: Map.get(tokens, :reasoning, 0) + Map.get(usage, :reasoning, 0)
       }, MapSet.put(seen, id)}
    end
  end

  defp maybe_add_usage(tokens, %Event{usage: usage}, seen) do
    {%{
       input: tokens.input + usage.input,
       output: tokens.output + usage.output,
       cache_read: tokens.cache_read + usage.cache_read,
       cache_creation: tokens.cache_creation + usage.cache_creation,
       reasoning: Map.get(tokens, :reasoning, 0) + Map.get(usage, :reasoning, 0)
     }, seen}
  end

  defp user_started_turn?(%Event{content: content}) do
    case content do
      bin when is_binary(bin) -> true
      list when is_list(list) -> not Enum.any?(list, &match?(%{"type" => "tool_result"}, &1))
      _ -> false
    end
  end

  defp classify_user_input(content) when is_binary(content) do
    cond do
      String.starts_with?(content, "<command-name>") ->
        name =
          case Regex.run(~r{<command-name>(.*?)</command-name>}, content) do
            [_, n] -> n
            _ -> "command"
          end

        {:slash_command, name}

      true ->
        {:prompt, content}
    end
  end

  defp classify_user_input(list) when is_list(list) do
    text =
      list
      |> Enum.find_value(fn
        %{"type" => "text", "text" => t} when is_binary(t) -> t
        _ -> nil
      end)

    {:prompt, text || ""}
  end

  defp classify_user_input(_), do: {:prompt, ""}

  defp attach_tool_results(turns) do
    Enum.map(turns, fn %Turn{blocks: blocks} = turn ->
      results_by_id =
        for %Block{kind: :tool_result, data: %{tool_use_id: id} = data} <- blocks,
            into: %{},
            do: {id, data}

      paired =
        blocks
        |> Enum.map(fn
          %Block{kind: :tool_use, data: %{id: id} = data} = block ->
            %{block | data: Map.put(data, :result, Map.get(results_by_id, id))}

          %Block{kind: :tool_result} ->
            nil

          other ->
            other
        end)
        |> Enum.reject(&is_nil/1)

      %{turn | blocks: paired}
    end)
  end

  def pair_tool_results(turns), do: attach_tool_results(turns)

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
