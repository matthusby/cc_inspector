defmodule CcInspector.Sessions.CacheTest do
  # async: true is safe — tests use unique tmp dirs and the Cache keys by absolute path.
  use ExUnit.Case, async: true

  import CcInspector.SessionFixtures

  alias CcInspector.Sessions.Cache
  alias CcInspector.Sessions.Summary

  setup do
    {:ok, dir: sandbox_claude_dir!()}
  end

  describe "list_summaries/1" do
    test "returns a Summary per top-level session file", %{dir: dir} do
      write_session!(dir, "-Users-me-proj-a", "sess-a", [
        user_row(content: "first prompt"),
        assistant_row(message_id: "m1", content: [text_block("hi")])
      ])

      write_session!(dir, "-Users-me-proj-b", "sess-b", [
        user_row(content: "another prompt"),
        assistant_row(message_id: "m2", content: [text_block("yo")])
      ])

      summaries = Cache.list_summaries(dir)

      assert length(summaries) == 2
      assert Enum.all?(summaries, &match?(%Summary{}, &1))
      ids = summaries |> Enum.map(& &1.session_id) |> Enum.sort()
      assert ids == ["sess-a", "sess-b"]
    end

    test "ignores nested files like subagents and tool-results", %{dir: dir} do
      write_session!(dir, "-Users-me-proj", "main", [user_row(content: "hi")])

      # depth-3 file (subagent transcript) — should not show up
      sub_dir = Path.join([dir, "-Users-me-proj", "main", "subagents"])
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(sub_dir, "agent-1.jsonl"), Jason.encode!(user_row(content: "sub")))

      summaries = Cache.list_summaries(dir)
      assert Enum.map(summaries, & &1.session_id) == ["main"]
    end

    test "skips empty session files", %{dir: dir} do
      project = Path.join(dir, "-Users-me-proj")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "blank.jsonl"), "")

      assert Cache.list_summaries(dir) == []
    end
  end

  describe "summary/2 + turns/2" do
    test "summary/2 finds the session by id", %{dir: dir} do
      write_session!(dir, "-Users-me-proj", "abc-123", [
        user_row(content: "find me"),
        assistant_row(message_id: "m1", content: [text_block("ok")])
      ])

      summary = Cache.summary("abc-123", dir)
      assert %Summary{session_id: "abc-123", first_prompt_preview: "find me"} = summary
    end

    test "summary/2 returns nil when session does not exist", %{dir: dir} do
      assert Cache.summary("nope", dir) == nil
    end

    test "turns/2 returns parsed turns for the session", %{dir: dir} do
      write_session!(dir, "-Users-me-proj", "with-turns", [
        user_row(content: "first"),
        assistant_row(content: [text_block("hi")]),
        user_row(content: "second"),
        assistant_row(content: [text_block("there")])
      ])

      turns = Cache.turns("with-turns", dir)
      assert length(turns) == 2
      assert Enum.map(turns, & &1.user_text) == ["first", "second"]
    end

    test "turns/2 returns nil when session does not exist", %{dir: dir} do
      assert Cache.turns("missing", dir) == nil
    end
  end

  describe "cache invalidation" do
    test "re-parses when mtime changes", %{dir: dir} do
      path =
        write_session!(dir, "-Users-me-proj", "mut", [
          user_row(content: "v1")
        ])

      # Force mtime well in the past so a later write's mtime is strictly newer
      old = {{2020, 1, 1}, {0, 0, 0}}
      File.touch!(path, old)

      first = Cache.summary("mut", dir)
      assert first.first_prompt_preview == "v1"

      File.write!(path, Jason.encode!(user_row(content: "v2")) <> "\n")
      File.touch!(path, {{2030, 1, 1}, {0, 0, 0}})

      second = Cache.summary("mut", dir)
      assert second.first_prompt_preview == "v2"
    end

    test "returns the same parsed events on cache hit (mtime+size unchanged)", %{dir: dir} do
      path =
        write_session!(dir, "-Users-me-proj", "stable", [
          user_row(content: "stable prompt"),
          assistant_row(message_id: "m1", content: [text_block("ok")])
        ])

      # Pin mtime so consecutive reads see the same stat
      File.touch!(path, {{2025, 6, 1}, {0, 0, 0}})

      a = Cache.summary("stable", dir)
      b = Cache.summary("stable", dir)
      assert a == b
    end

    test "invalidate/1 forces a re-parse on next read", %{dir: dir} do
      path =
        write_session!(dir, "-Users-me-proj", "inv", [
          user_row(content: "v1")
        ])

      File.touch!(path, {{2025, 6, 1}, {0, 0, 0}})

      assert Cache.summary("inv", dir).first_prompt_preview == "v1"

      # Overwrite without changing mtime to simulate a stale cache scenario
      File.write!(path, Jason.encode!(user_row(content: "v2")) <> "\n")
      File.touch!(path, {{2025, 6, 1}, {0, 0, 0}})

      Cache.invalidate(path)

      assert Cache.summary("inv", dir).first_prompt_preview == "v2"
    end
  end

  describe "provider snapshots" do
    test "miss until stored, then serve the value until invalidated" do
      assert Cache.get_provider(:cache_test_probe) == :miss

      Cache.put_provider(:cache_test_probe, %{sessions: 3})
      assert Cache.get_provider(:cache_test_probe) == {:ok, %{sessions: 3}}

      Cache.put_provider(:cache_test_probe, %{sessions: 4})
      assert Cache.get_provider(:cache_test_probe) == {:ok, %{sessions: 4}}

      Cache.invalidate_provider(:cache_test_probe)
      assert Cache.get_provider(:cache_test_probe) == :miss
    end
  end
end
