defmodule CcInspector.Sessions.OpenCodeQueryTest do
  # Not async: shares the process-wide provider cache with OpenCodeTest.
  # Exercises the sqlite3-backed queries against a fixture database holding
  # both schema generations (OpenCode 1 `session`/`message`/`part` and
  # OpenCode 2 `session_v2`/`session_message`).
  use ExUnit.Case, async: false

  alias CcInspector.Sessions.{Cache, OpenCode}
  alias CcInspector.Sessions.Turns.Block

  @session_v2_id "ses_v2main0000000000000000"
  @session_v2_sub_id "ses_v2sub00000000000000000"
  @session_v2_plain_id "ses_v2plain000000000000000"
  @session_v1_id "ses_v1main0000000000000000"
  @session_migrated_id "ses_migrated00000000000000"

  setup do
    unless System.find_executable("sqlite3"), do: {:skip, "sqlite3 not available"}

    # Recent timestamps so rows fall inside the usage window. Session and
    # message times anchor to separate bases: `base` orders the session rows,
    # while messages snap to one hour boundary so usage buckets are stable.
    base = System.system_time(:millisecond) - 3_600_000
    hour = div(base, 3_600_000)
    t = hour * 3_600_000

    dir = Path.expand("../tmp/test_opencode_sqlite", __DIR__)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    original_dir = Application.fetch_env!(:cc_inspector, :opencode_data_dir)
    Application.put_env(:cc_inspector, :opencode_data_dir, dir)

    seed_database(Path.join(dir, "opencode.db"), base, t)

    on_exit(fn ->
      Application.put_env(:cc_inspector, :opencode_data_dir, original_dir)
      Cache.invalidate_provider(:opencode_summaries)
      Cache.invalidate_provider(:opencode_usage)
      Cache.invalidate_provider(:opencode_error)
      File.rm_rf!(dir)
    end)

    Cache.invalidate_provider(:opencode_summaries)
    Cache.invalidate_provider(:opencode_usage)
    Cache.invalidate_provider(:opencode_error)

    %{hour: hour, t: t}
  end

  test "refresh lists sessions from both schema generations", %{hour: hour} do
    assert :ok = OpenCode.refresh()

    assert {:ok, summaries} = OpenCode.list_summaries_result()

    ids = Enum.map(summaries, & &1.session_id)
    assert @session_v2_id in ids
    assert @session_v2_plain_id in ids
    assert @session_v1_id in ids
    # Subagent sessions stay out of the index.
    refute @session_v2_sub_id in ids
    # Newest first.
    assert Enum.at(ids, 0) == @session_v2_id
    # A session OpenCode 2 migrated appears once, from the OpenCode 2 tables.
    assert Enum.count(ids, &(&1 == @session_migrated_id)) == 1

    migrated = Enum.find(summaries, &(&1.session_id == @session_migrated_id))
    assert migrated.ai_title == "Migrated V2"
    assert migrated.tokens.input == 777

    v2 = Enum.find(summaries, &(&1.session_id == @session_v2_id))

    assert v2.model == "zai/glm-5.3"
    assert v2.first_prompt_preview == "Fix the login bug"
    assert v2.user_message_count == 1
    assert v2.assistant_message_count == 1
    assert v2.turn_count == 1
    assert v2.tool_call_count == 1
    assert v2.tokens.input == 1000
    assert v2.tokens.cache_read == 8000
    assert v2.cost == 1.5
    assert v2.project_slug == "v2proj"
    assert v2.ai_title == "V2 session"

    # A missing session.model column falls back to the last assistant message.
    plain = Enum.find(summaries, &(&1.session_id == @session_v2_plain_id))
    assert plain.model == "zai/glm-mini"

    v1 = Enum.find(summaries, &(&1.session_id == @session_v1_id))
    assert v1.model == "zai/glm-5.1"
    assert v1.first_prompt_preview == "V1 prompt"
    assert v1.tool_call_count == 1

    # Subagent token usage is attributed to the parent session.
    usage = OpenCode.usage_by_session()
    assert usage[@session_v2_id][hour].input == 15
    # Migrated sessions count their usage once, from the OpenCode 2 tables
    # (the legacy copy of the messages is ignored).
    assert usage[@session_migrated_id][hour].input == 20
  end

  test "get_turns renders OpenCode 2 sessions", %{t: t} do
    turns = OpenCode.get_turns(@session_v2_id)

    assert [turn] = turns
    assert turn.user_text == "Fix the login bug"
    assert turn.model == "zai/glm-5.3"
    assert turn.tokens.input == 10
    assert turn.tokens.reasoning == 2
    assert turn.cost == 0.25

    assert %Block{kind: :thinking} = Enum.find(turn.blocks, &match?(%Block{kind: :thinking}, &1))
    assert %Block{kind: :text} = Enum.find(turn.blocks, &match?(%Block{kind: :text}, &1))

    assert %Block{
             kind: :tool_use,
             data: %{id: "call-1", name: "shell", result: %{content: "2 tests"}}
           } = Enum.find(turn.blocks, &match?(%Block{kind: :tool_use}, &1))

    # V2 user timestamps survive the reshape into parts.
    assert turn.started_at == DateTime.from_unix!(t + 500, :millisecond)
  end

  test "get_turns still renders OpenCode 1 sessions" do
    assert [turn] = OpenCode.get_turns(@session_v1_id)
    assert turn.user_text == "V1 prompt"
    assert turn.model == "zai/glm-5.1"

    assert %Block{kind: :tool_use, data: %{id: "call-9", name: "edit"}} =
             Enum.find(turn.blocks, &match?(%Block{kind: :tool_use}, &1))
  end

  test "get_turns prefers OpenCode 2 messages for migrated sessions" do
    assert [turn] = OpenCode.get_turns(@session_migrated_id)
    assert turn.user_text == "Migrated prompt"
    # The legacy copy of the assistant message stays hidden, so its tokens
    # are not counted a second time.
    assert turn.tokens.input == 20
  end

  test "get_turns returns nothing for unknown or malformed session ids" do
    assert OpenCode.get_turns("ses_unknown00000000000000000") == []
    assert OpenCode.get_turns("not a valid id!") == []
  end

  defp seed_database(path, base, t) do
    sql = """
    CREATE TABLE session_v2 (
      id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT,
      time_created INTEGER, time_updated INTEGER, cost REAL,
      tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
      tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT
    );
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
      time_created INTEGER, data TEXT
    );
    CREATE TABLE session (
      id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, version TEXT,
      time_created INTEGER, time_updated INTEGER, cost REAL,
      tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
      tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT
    );
    CREATE TABLE message (
      id INTEGER PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT
    );
    CREATE TABLE part (
      id INTEGER PRIMARY KEY, session_id TEXT, message_id INTEGER,
      time_created INTEGER, data TEXT
    );

    INSERT INTO session_v2 VALUES
      ('#{@session_v2_id}', NULL, '/tmp/v2proj', 'V2 session', '2.0.0-beta',
       #{base - 1000}, #{base + 1000}, 1.5, 1000, 200, 50, 8000, 100,
       '{"id":"glm-5.3","providerID":"zai"}'),
      ('#{@session_v2_sub_id}', '#{@session_v2_id}', '/tmp/v2proj', 'Sub session', '2.0.0-beta',
       #{base - 500}, #{base - 100}, 0.0, 0, 0, 0, 0, 0, NULL),
      ('#{@session_v2_plain_id}', NULL, '/tmp/v2plain', 'Plain session', '2.0.0-beta',
       #{base - 2000}, #{base}, 0.0, 10, 2, 0, 0, 0, NULL),
      ('#{@session_migrated_id}', NULL, '/tmp/migrated', 'Migrated V2', '2.0.0-beta',
       #{base - 3000}, #{base - 500}, 0.0, 777, 1, 0, 0, 0, NULL);

    INSERT INTO session_message VALUES
      ('msg-1', '#{@session_v2_id}', 'user', 1, #{t + 500},
       '{"time":{"created":#{t + 500}},"text":"Fix the login bug"}'),
      ('msg-2', '#{@session_v2_id}', 'assistant', 2, #{t + 600},
       '{"time":{"created":#{t + 600},"completed":#{t + 700}},"cost":0.25,"model":{"id":"glm-5.3","providerID":"zai"},"tokens":{"input":10,"output":3,"reasoning":2,"cache":{"read":8,"write":1}},"content":[{"type":"reasoning","text":"Consider the tests"},{"type":"tool","id":"call-1","name":"shell","state":{"status":"completed","input":{"command":"mix test"},"output":"2 tests"}},{"type":"text","text":"All green"}]}'),
      ('msg-3', '#{@session_v2_id}', 'synthetic', 3, #{t + 800},
       '{"time":{"created":#{t + 800}},"text":"shell output"}'),
      ('msg-4', '#{@session_v2_sub_id}', 'assistant', 1, #{t + 900},
       '{"time":{"created":#{t + 900}},"cost":0.1,"model":{"id":"glm-5.3","providerID":"zai"},"tokens":{"input":5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"text","text":"Sub reply"}]}'),
      ('msg-5', '#{@session_v2_plain_id}', 'assistant', 1, #{t + 1000},
       '{"time":{"created":#{t + 1000}},"model":{"id":"glm-mini","providerID":"zai"},"content":[{"type":"text","text":"Plain reply"}]}'),
      ('msg-6', '#{@session_migrated_id}', 'assistant', 1, #{t + 1100},
       '{"time":{"created":#{t + 1100}},"tokens":{"input":20,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"text","text":"Migrated reply"}]}'),
      ('msg-7', '#{@session_migrated_id}', 'user', 2, #{t + 1050},
       '{"time":{"created":#{t + 1050}},"text":"Migrated prompt"}');

    -- The migrated session also exists in the OpenCode 1 tables, as a
    -- would-be duplicate with different data. The guards must prefer the
    -- OpenCode 2 copy.
    INSERT INTO session VALUES
      ('#{@session_migrated_id}', NULL, '/tmp/migrated', 'Migrated V1', '1.18.21',
       #{base - 3000}, #{base - 500}, 0.0, 999, 1, 0, 0, 0, NULL);

    INSERT INTO session VALUES
      ('#{@session_v1_id}', NULL, '/tmp/v1proj', 'V1 session', '1.18.21',
       #{base - 5000}, #{base - 1000}, 0.5, 500, 100, 10, 4000, 20,
       '{"id":"glm-5.1","providerID":"zai"}');

    INSERT INTO message VALUES
      (1, '#{@session_v1_id}', #{base - 4000},
       '{"role":"user","time":{"created":#{base - 4000}}}'),
      (2, '#{@session_v1_id}', #{base - 3900},
       '{"role":"assistant","providerID":"zai","modelID":"glm-5.1","time":{"created":#{base - 3900},"completed":#{base - 3800}},"cost":0.1,"tokens":{"input":7,"output":2,"reasoning":1,"cache":{"read":3,"write":0}}}'),
      (3, '#{@session_migrated_id}', #{t + 1200},
       '{"role":"assistant","providerID":"zai","modelID":"glm-5.1","time":{"created":#{t + 1200}},"cost":0.0,"tokens":{"input":30,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');

    INSERT INTO part VALUES
      (1, '#{@session_v1_id}', 1, #{base - 4000}, '{"type":"text","text":"V1 prompt"}'),
      (2, '#{@session_v1_id}', 2, #{base - 3890}, '{"type":"tool","callID":"call-9","tool":"edit","state":{"status":"completed","input":{"path":"lib/a.ex"},"output":"done"}}'),
      (3, '#{@session_v1_id}', 2, #{base - 3880}, '{"type":"text","text":"V1 reply"}');
    """

    {_, 0} = System.cmd("sqlite3", [path, sql])
  end
end
