defmodule CcInspector.Sessions.Parser do
  @moduledoc """
  Pure JSONL → typed event parsing for Claude Code session files.
  """

  defmodule Event do
    @moduledoc false
    defstruct [
      :uuid,
      :parent_uuid,
      :type,
      :timestamp,
      :message_id,
      :role,
      :model,
      :content,
      :usage,
      :stop_reason,
      :prompt_id,
      :is_meta,
      :is_sidechain,
      :cwd,
      :git_branch,
      :session_id,
      :version,
      :ai_title,
      :raw
    ]
  end

  def parse_file(path) do
    path
    |> File.stream!([:read_ahead])
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == ""))
    |> Stream.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, raw} -> [build_event(raw)]
        {:error, _} -> []
      end
    end)
    |> Enum.to_list()
  end

  def parse_line(line) when is_binary(line) do
    with {:ok, raw} <- Jason.decode(line) do
      {:ok, build_event(raw)}
    end
  end

  defp build_event(raw) do
    %Event{
      uuid: raw["uuid"],
      parent_uuid: raw["parentUuid"],
      type: classify(raw["type"]),
      timestamp: parse_ts(raw["timestamp"]),
      message_id: get_in(raw, ["message", "id"]),
      role: parse_role(get_in(raw, ["message", "role"])),
      model: get_in(raw, ["message", "model"]),
      content: get_in(raw, ["message", "content"]),
      usage: parse_usage(get_in(raw, ["message", "usage"])),
      stop_reason: get_in(raw, ["message", "stop_reason"]),
      prompt_id: raw["promptId"],
      is_meta: raw["isMeta"] == true,
      is_sidechain: raw["isSidechain"] == true,
      cwd: raw["cwd"],
      git_branch: raw["gitBranch"],
      session_id: raw["sessionId"],
      version: raw["version"],
      ai_title: raw["aiTitle"],
      raw: raw
    }
  end

  defp classify("user"), do: :user
  defp classify("assistant"), do: :assistant
  defp classify("system"), do: :system
  defp classify("file-history-snapshot"), do: :file_history
  defp classify("attachment"), do: :attachment
  defp classify("permission-mode"), do: :permission_mode
  defp classify("queue-operation"), do: :queue_operation
  defp classify("last-prompt"), do: :last_prompt
  defp classify("ai-title"), do: :ai_title
  defp classify(other) when is_binary(other), do: {:other, other}
  defp classify(_), do: :unknown

  defp parse_role("user"), do: :user
  defp parse_role("assistant"), do: :assistant
  defp parse_role(_), do: nil

  defp parse_usage(nil), do: nil

  defp parse_usage(map) when is_map(map) do
    %{
      input: map["input_tokens"] || 0,
      output: map["output_tokens"] || 0,
      cache_read: map["cache_read_input_tokens"] || 0,
      cache_creation: map["cache_creation_input_tokens"] || 0
    }
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
