defmodule CcInspector.Sessions.OpenCode do
  @moduledoc false

  require Logger

  alias CcInspector.Sessions.{Cache, OpenCodeParser, Usage}

  # A day wider than the dashboard window, so buckets on the boundary survive
  # the shift from UTC hours to local days.
  @usage_window_days 31

  # OpenCode 2 and OpenCode 1 share the database file but write different
  # tables: `session_v2`/`session_message` for OpenCode 2, and
  # `session`/`message`/`part` for OpenCode 1. Both eras are unioned so
  # pre-switch history keeps rendering, with the legacy branches excluded
  # wherever a session was migrated into the OpenCode 2 tables. The
  # `opencode db` CLI used previously no longer exists in OpenCode 2, so the
  # file is read directly through the `sqlite3` executable — the same file the
  # watcher already monitors.
  @summary_query """
  SELECT * FROM (
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
        CASE WHEN json_valid(s.model)
          THEN json_extract(s.model, '$.providerID') || '/' || json_extract(s.model, '$.id')
          ELSE s.model END,
        (SELECT json_extract(sm.data, '$.model.providerID') || '/' || json_extract(sm.data, '$.model.id')
         FROM session_message sm
         WHERE sm.session_id = s.id AND sm.type = 'assistant'
         ORDER BY sm.time_created DESC LIMIT 1)
      ) AS model,
      (SELECT COUNT(*) FROM session_message sm
       WHERE sm.session_id = s.id AND sm.type = 'user')
        AS user_message_count,
      (SELECT COUNT(*) FROM session_message sm
       WHERE sm.session_id = s.id AND sm.type = 'assistant')
        AS assistant_message_count,
      (SELECT COUNT(*)
       FROM session_message sm, json_each(sm.data, '$.content') c
       WHERE sm.session_id = s.id AND json_extract(c.value, '$.type') = 'tool')
        AS tool_call_count,
      (SELECT json_extract(sm.data, '$.text')
       FROM session_message sm
       WHERE sm.session_id = s.id AND sm.type = 'user'
       ORDER BY sm.time_created, sm.seq LIMIT 1)
        AS first_prompt
    FROM session_v2 s
    WHERE s.parent_id IS NULL

    UNION ALL

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
        CASE WHEN json_valid(s.model)
          THEN json_extract(s.model, '$.providerID') || '/' || json_extract(s.model, '$.id')
          ELSE s.model END,
        (SELECT json_extract(m.data, '$.providerID') || '/' || json_extract(m.data, '$.modelID')
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
      -- OpenCode 2 migrates legacy sessions into session_v2; without this
      -- guard every migrated session would be listed twice.
      AND s.id NOT IN (SELECT id FROM session_v2)
  )
  ORDER BY time_updated DESC
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

  Reads the last snapshot `refresh/0` produced and never queries inline: a
  refresh spawns `sqlite3` twice, and the index should never wait on a
  provider nobody is looking at.

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
  sessions blinking out of the index whenever the database can't be read.
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

      # A missing `sqlite3` executable or database file is not a failure —
      # plenty of machines simply don't have OpenCode, and surfacing that as
      # an error would be permanent noise.
      {:error, "executable not found"} ->
        {:ok, %{summaries: [], usage: %{}}}

      {:error, "database file not found"} ->
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
  # The two eras are unioned like the summary query.
  defp usage_query(cutoff_ms) do
    """
    SELECT
      session_id,
      hour,
      SUM(input) AS input,
      SUM(output) AS output,
      SUM(reasoning) AS reasoning,
      SUM(cache_read) AS cache_read,
      SUM(cache_creation) AS cache_creation
    FROM (
      SELECT
        COALESCE(s.parent_id, sm.session_id) AS session_id,
        sm.time_created / 3600000 AS hour,
        COALESCE(json_extract(sm.data, '$.tokens.input'), 0) AS input,
        COALESCE(json_extract(sm.data, '$.tokens.output'), 0) AS output,
        COALESCE(json_extract(sm.data, '$.tokens.reasoning'), 0) AS reasoning,
        COALESCE(json_extract(sm.data, '$.tokens.cache.read'), 0) AS cache_read,
        COALESCE(json_extract(sm.data, '$.tokens.cache.write'), 0) AS cache_creation
      FROM session_message sm
      LEFT JOIN session_v2 s ON s.id = sm.session_id
      WHERE sm.time_created >= #{cutoff_ms} AND sm.type = 'assistant'

      UNION ALL

      SELECT
        COALESCE(s.parent_id, m.session_id) AS session_id,
        m.time_created / 3600000 AS hour,
        COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS input,
        COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS output,
        COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0) AS reasoning,
        COALESCE(json_extract(m.data, '$.tokens.cache.read'), 0) AS cache_read,
        COALESCE(json_extract(m.data, '$.tokens.cache.write'), 0) AS cache_creation
      FROM message m
      LEFT JOIN session s ON s.id = m.session_id
      WHERE m.time_created >= #{cutoff_ms}
        -- Migrated sessions have copies of their messages in session_message;
        -- counting both eras would double the usage.
        AND m.session_id NOT IN (SELECT id FROM session_v2)
    )
    GROUP BY session_id, hour
    """
  end

  def get_summary(session_id) do
    Enum.find(list_summaries(), &(&1.session_id == session_id))
  end

  def get_turns(session_id) do
    if valid_session_id?(session_id) do
      case query(turns_query(session_id)) do
        {:ok, rows} -> OpenCodeParser.turns_from_rows(rows)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  # One row per message, in both schema generations. The OpenCode 2 branch
  # reshapes `session_message` rows into the shape the parser already
  # understands: the `type` column becomes `role`, the nested model object is
  # lifted to `modelID`/`providerID`, and `content` (or the top-level `text`
  # user messages use) becomes the parts array.
  defp turns_query(session_id) do
    """
    SELECT * FROM (
      SELECT
        json_patch(
          json_patch(json_object('role', sm.type), json_remove(sm.data, '$.content', '$.text')),
          json_object(
            'modelID', json_extract(sm.data, '$.model.id'),
            'providerID', json_extract(sm.data, '$.model.providerID')
          )
        ) AS info,
        COALESCE(
          json_extract(sm.data, '$.content'),
          json_array(json_object('type', 'text', 'text', json_extract(sm.data, '$.text'))),
          '[]'
        ) AS parts,
        sm.time_created AS sort_time,
        sm.seq AS sort_seq
      FROM session_message sm
      WHERE sm.session_id = '#{session_id}'

      UNION ALL

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
        ) AS parts,
        m.time_created AS sort_time,
        m.id AS sort_seq
      FROM message m
      WHERE m.session_id = '#{session_id}'
        -- Migrated sessions carry their history in session_message already.
        AND m.session_id NOT IN (SELECT id FROM session_v2)
    )
    ORDER BY sort_time, sort_seq
    """
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

  # Runs a read-only query and decodes it. `sqlite3 -json` prints nothing at
  # all for an empty result, which decodes as an empty list.
  defp query(sql) do
    with {:ok, output} <- command(sql) do
      if String.trim(output) == "" do
        {:ok, []}
      else
        case Jason.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, %Jason.DecodeError{}} -> {:error, "response was not valid JSON"}
        end
      end
    end
  end

  defp command(sql) do
    executable = Application.get_env(:cc_inspector, :opencode_sqlite, "sqlite3")
    database = Path.join(data_dir(), "opencode.db")

    with {:ok, path} <- find_executable(executable),
         :ok <- ensure_database(database) do
      case System.cmd(path, ["-json", database, sql]) do
        {output, 0} -> {:ok, output}
        {_output, status} -> {:error, "command exited with status #{status}"}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp find_executable(path) do
    cond do
      Path.type(path) == :absolute and File.regular?(path) -> {:ok, path}
      found = System.find_executable(path) -> {:ok, found}
      true -> {:error, "executable not found"}
    end
  end

  # sqlite3 would happily create an empty database file otherwise.
  defp ensure_database(database) do
    if File.exists?(database), do: :ok, else: {:error, "database file not found"}
  end

  defp valid_session_id?(session_id) when is_binary(session_id),
    do: Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, session_id)

  defp valid_session_id?(_), do: false
end
