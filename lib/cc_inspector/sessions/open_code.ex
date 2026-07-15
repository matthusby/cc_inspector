defmodule CcInspector.Sessions.OpenCode do
  @moduledoc false

  require Logger

  alias CcInspector.Sessions.OpenCodeParser

  @summary_query """
  SELECT
    s.id,
    s.directory,
    s.title,
    s.version,
    s.time_created,
    s.time_updated,
    s.cost,
    s.tokens_input,
    s.tokens_output,
    s.tokens_reasoning,
    s.tokens_cache_read,
    s.tokens_cache_write,
    COALESCE(
      s.model,
      (SELECT json_extract(m.data, '$.modelID')
       FROM message m
       WHERE m.session_id = s.id AND json_extract(m.data, '$.role') = 'assistant'
       ORDER BY m.time_created DESC LIMIT 1)
    ) AS model,
    (SELECT COUNT(*) FROM message m
     WHERE m.session_id = s.id AND json_extract(m.data, '$.role') = 'user')
      AS user_message_count,
    (SELECT COUNT(*) FROM message m
     WHERE m.session_id = s.id AND json_extract(m.data, '$.role') = 'assistant')
      AS assistant_message_count,
    (SELECT COUNT(*) FROM part p
     WHERE p.session_id = s.id AND json_extract(p.data, '$.type') = 'tool')
      AS tool_call_count,
    (SELECT json_extract(p.data, '$.text')
     FROM message m
     JOIN part p ON p.message_id = m.id
     WHERE m.session_id = s.id
       AND json_extract(m.data, '$.role') = 'user'
       AND json_extract(p.data, '$.type') = 'text'
     ORDER BY m.time_created, p.time_created LIMIT 1)
      AS first_prompt
  FROM session s
  WHERE s.parent_id IS NULL
  ORDER BY s.time_updated DESC
  """

  def list_summaries do
    case command(["db", @summary_query, "--format", "json", "--pure"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, rows} when is_list(rows) -> Enum.map(rows, &OpenCodeParser.summary_from_row/1)
          _ -> []
        end

      {:error, reason} ->
        Logger.debug("OpenCode sessions unavailable: #{reason}")
        []
    end
  end

  def get_summary(session_id) do
    Enum.find(list_summaries(), &(&1.session_id == session_id))
  end

  def get_turns(session_id) do
    if valid_session_id?(session_id) do
      query = """
      SELECT
        m.data AS info,
        COALESCE(
          (SELECT json_group_array(json(ordered.data))
           FROM (
             SELECT p.data
             FROM part p
             WHERE p.message_id = m.id
             ORDER BY p.time_created, p.id
           ) AS ordered),
          '[]'
        ) AS parts
      FROM message m
      WHERE m.session_id = '#{session_id}'
      ORDER BY m.time_created, m.id
      """

      case command(["db", query, "--format", "json", "--pure"]) do
        {:ok, output} ->
          case Jason.decode(output) do
            {:ok, rows} -> OpenCodeParser.turns_from_rows(rows)
            _ -> []
          end

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  def data_dir do
    Application.fetch_env!(:cc_inspector, :opencode_data_dir)
  end

  def database_file?(path) do
    path in [
      Path.join(data_dir(), "opencode.db"),
      Path.join(data_dir(), "opencode.db-wal"),
      Path.join(data_dir(), "opencode.db-shm")
    ]
  end

  defp command(args) do
    executable = Application.get_env(:cc_inspector, :opencode_cli, "opencode")

    case find_executable(executable) do
      nil ->
        {:error, "executable not found"}

      path ->
        case System.cmd(path, args) do
          {output, 0} -> {:ok, output}
          {_output, status} -> {:error, "command exited with status #{status}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp find_executable(path) do
    if Path.type(path) == :absolute and File.regular?(path) do
      path
    else
      System.find_executable(path)
    end
  end

  defp valid_session_id?(session_id) when is_binary(session_id),
    do: Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, session_id)

  defp valid_session_id?(_), do: false
end
