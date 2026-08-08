defmodule CcInspector.Sessions.OpenCode do
  @moduledoc false

  require Logger

  alias CcInspector.Sessions.{Cache, OpenCodeParser, Usage}

  # The CLI exits before flushing stdout perhaps half the time, handing back a
  # partial payload with a success status — truncated at an exact 32KB boundary,
  # measured at ~50% of attempts against a 1.1MB response. Truncated JSON never
  # parses, so a failed decode after a clean exit means "ask again", not "no
  # data". Eight attempts puts the odds of losing every one below 1%; results are
  # cached and loaded off the request path, so the retries cost nothing visible.
  @max_query_attempts 8

  # A day wider than the dashboard window, so buckets on the boundary survive
  # the shift from UTC hours to local days.
  @usage_window_days 31

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
    case list_summaries_result() do
      {:ok, summaries} -> summaries
      {:error, _reason} -> []
    end
  end

  @doc """
  Like `list_summaries/0` but distinguishes "nothing to read" from "couldn't
  read", so the index can say which provider is missing.

  Reads the last snapshot `refresh/0` produced and never queries inline. Each
  `opencode db` invocation costs ~470 ms of CLI startup before it runs any SQL,
  and the two queries behind a snapshot need retries often enough that a cold
  read added seven seconds to every session scan — which stalled the whole index
  behind a provider nobody was waiting on.

  A miss with no recorded error means the first refresh hasn't landed yet. That
  is "not yet", not "broken", so it reports an empty list rather than a failure.
  """
  def list_summaries_result do
    case Cache.get_provider(:opencode_summaries) do
      {:ok, summaries} ->
        {:ok, summaries}

      :miss ->
        case Cache.get_provider(:opencode_error) do
          {:ok, reason} -> {:error, reason}
          :miss -> {:ok, []}
        end
    end
  end

  @doc """
  Re-queries OpenCode and swaps in a new snapshot. Driven by the watcher, off
  the read path.

  A failed run leaves the previous snapshot in place: stale sessions beat
  sessions blinking out of the index every time the CLI truncates its output.
  """
  def refresh do
    case load_snapshot() do
      {:ok, %{summaries: summaries, usage: usage}} ->
        Cache.put_provider(:opencode_usage, usage)
        Cache.put_provider(:opencode_summaries, summaries)
        Cache.invalidate_provider(:opencode_error)
        :ok

      {:error, reason} ->
        Logger.debug("OpenCode sessions unavailable: #{reason}")
        Cache.put_provider(:opencode_error, reason)
        {:error, reason}
    end
  end

  defp load_snapshot do
    case query(@summary_query) do
      {:ok, rows} when is_list(rows) ->
        usage = load_usage_by_session()

        summaries =
          Enum.map(rows, fn row ->
            summary = OpenCodeParser.summary_from_row(row)
            %{summary | usage: Map.get(usage, summary.session_id, Usage.new())}
          end)

        {:ok, %{summaries: summaries, usage: usage}}

      {:ok, _other} ->
        {:ok, %{summaries: [], usage: %{}}}

      # A missing `opencode` executable is not a failure — plenty of installs
      # simply don't have it, and surfacing that as an error would be permanent
      # noise.
      {:error, "executable not found"} ->
        {:ok, %{summaries: [], usage: %{}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hourly token buckets per session over the dashboard window, from the snapshot
  `refresh/0` last loaded.
  """
  def usage_by_session do
    case Cache.get_provider(:opencode_usage) do
      {:ok, usage} -> usage
      :miss -> %{}
    end
  end

  defp load_usage_by_session do
    cutoff_ms =
      DateTime.utc_now()
      |> DateTime.add(-@usage_window_days * 86_400, :second)
      |> DateTime.to_unix(:millisecond)

    case query(usage_query(cutoff_ms)) do
      {:ok, rows} when is_list(rows) -> OpenCodeParser.usage_from_rows(rows)
      _ -> %{}
    end
  end

  # Messages carry their own token usage; the session row's totals are a
  # lifetime figure with no time dimension. Subagent messages are attributed to
  # the parent session so they land on a session the index actually lists.
  defp usage_query(cutoff_ms) do
    """
    SELECT
      COALESCE(s.parent_id, m.session_id) AS session_id,
      m.time_created / 3600000 AS hour,
      SUM(COALESCE(json_extract(m.data, '$.tokens.input'), 0)) AS input,
      SUM(COALESCE(json_extract(m.data, '$.tokens.output'), 0)) AS output,
      SUM(COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0)) AS reasoning,
      SUM(COALESCE(json_extract(m.data, '$.tokens.cache.read'), 0)) AS cache_read,
      SUM(COALESCE(json_extract(m.data, '$.tokens.cache.write'), 0)) AS cache_creation
    FROM message m
    LEFT JOIN session s ON s.id = m.session_id
    WHERE m.time_created >= #{cutoff_ms}
    GROUP BY session_id, hour
    """
  end

  def get_summary(session_id) do
    Enum.find(list_summaries(), &(&1.session_id == session_id))
  end

  def get_turns(session_id) do
    if valid_session_id?(session_id) do
      sql = """
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

      case query(sql) do
        {:ok, rows} -> OpenCodeParser.turns_from_rows(rows)
        {:error, _reason} -> []
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

  # Runs a read-only query and decodes it, retrying when the CLI exits cleanly
  # but hands back something that isn't valid JSON. Without this the large
  # session query silently truncates most of the time, `Jason.decode` fails, and
  # every OpenCode session disappears from the index until the next refresh
  # happens to succeed.
  defp query(sql, attempt \\ 1) do
    with {:ok, output} <- command(["db", sql, "--format", "json", "--pure"]),
         {:ok, decoded} <- Jason.decode(output) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{}} when attempt < @max_query_attempts ->
        Logger.debug("OpenCode returned a partial response, retrying (#{attempt})")
        # Truncation is load-correlated, so back-to-back retries tend to fail
        # together. A short backoff decorrelates them. Runs inside the async
        # load, never on a caller that's waiting to render.
        Process.sleep(attempt * 25)
        query(sql, attempt + 1)

      {:error, %Jason.DecodeError{}} ->
        {:error, "response was not valid JSON after #{@max_query_attempts} attempts"}

      {:error, reason} ->
        {:error, reason}
    end
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
