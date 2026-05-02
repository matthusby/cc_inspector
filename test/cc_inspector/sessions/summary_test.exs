defmodule CcInspector.Sessions.SummaryTest do
  use ExUnit.Case, async: true

  import CcInspector.SessionFixtures

  alias CcInspector.Sessions.Summary

  @path "/Users/me/.claude/projects/-Users-me-proj/sess-1.jsonl"

  describe "from_events/2" do
    test "returns nil for an empty event list" do
      assert Summary.from_events([], @path) == nil
    end

    test "captures session_id and project_slug from path, falls back to slug-derived cwd" do
      summary = Summary.from_events([event(:user, content: "hi")], @path)

      assert summary.session_id == "sess-1"
      assert summary.project_slug == "-Users-me-proj"
      assert summary.project_cwd == "/Users/me/proj"
    end

    test "captures cwd, git_branch, version from the first event that has them" do
      events = [
        event(:user,
          cwd: "/real/cwd",
          git_branch: "feature/x",
          version: "1.0.99",
          content: "first"
        ),
        event(:assistant,
          model: "claude-opus-4-7",
          content: [%{"type" => "text", "text" => "ok"}]
        )
      ]

      summary = Summary.from_events(events, @path)

      assert summary.project_cwd == "/real/cwd"
      assert summary.git_branch == "feature/x"
      assert summary.version == "1.0.99"
      assert summary.model == "claude-opus-4-7"
    end

    test "duration_ms is computed between earliest and latest timestamp" do
      t1 = ~U[2026-04-29 12:00:00Z]
      t2 = ~U[2026-04-29 12:00:05Z]
      t3 = ~U[2026-04-29 12:00:03Z]

      events = [
        event(:user, timestamp: t2, content: "x"),
        event(:assistant, timestamp: t1, content: [%{"type" => "text", "text" => "ok"}]),
        event(:user, timestamp: t3, content: "y")
      ]

      summary = Summary.from_events(events, @path)
      assert summary.started_at == t1
      assert summary.last_activity_at == t2
      assert summary.duration_ms == 5_000
    end

    test "counts user-initiated turns and skips meta + tool_result-only user events" do
      events = [
        event(:user, content: "first prompt"),
        event(:assistant, content: [%{"type" => "text", "text" => "reply"}]),
        # tool_result delivery (NOT a new turn)
        event(:user,
          content: [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "out"}]
        ),
        # meta user event must be ignored
        event(:user, is_meta: true, content: "ignored"),
        # local-command-caveat must be ignored
        event(:user, content: "<local-command-caveat>foo</local-command-caveat>"),
        event(:user, content: "second prompt"),
        event(:assistant, content: [%{"type" => "text", "text" => "another"}])
      ]

      summary = Summary.from_events(events, @path)

      assert summary.turn_count == 2
      assert summary.user_message_count == 2
      assert summary.assistant_message_count == 2
    end

    test "counts tool_use blocks across assistant messages" do
      events = [
        event(:user, content: "prompt"),
        event(:assistant,
          content: [
            %{"type" => "text", "text" => "ok"},
            %{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}},
            %{"type" => "tool_use", "id" => "t2", "name" => "Read", "input" => %{}}
          ]
        ),
        event(:assistant,
          content: [%{"type" => "tool_use", "id" => "t3", "name" => "Edit", "input" => %{}}]
        )
      ]

      assert Summary.from_events(events, @path).tool_call_count == 3
    end

    test "dedupes token usage by message_id across multiple records" do
      usage = usage(input: 100, output: 50, cache_read: 10, cache_creation: 1)

      events = [
        event(:user, content: "prompt"),
        # Two assistant rows with the same message_id (one API call, multiple blocks)
        event(:assistant, message_id: "msg_1", usage: usage, content: []),
        event(:assistant, message_id: "msg_1", usage: usage, content: []),
        # A separate API call with its own message_id contributes again
        event(:assistant,
          message_id: "msg_2",
          usage: usage(input: 5, output: 5, cache_read: 0, cache_creation: 0),
          content: []
        )
      ]

      tokens = Summary.from_events(events, @path).tokens
      assert tokens.input == 105
      assert tokens.output == 55
      assert tokens.cache_read == 10
      assert tokens.cache_creation == 1
    end

    test "first_prompt_preview captures the first non-meta user prompt and trims whitespace" do
      events = [
        event(:user, is_meta: true, content: "skip me"),
        event(:user, content: "  hello   world\nnew  line  "),
        event(:user, content: "second prompt — should not overwrite")
      ]

      summary = Summary.from_events(events, @path)
      assert summary.first_prompt_preview == "hello world new line"
    end

    test "first_prompt_preview pulls text from list-style user content" do
      content = [
        %{"type" => "image", "source" => "..."},
        %{"type" => "text", "text" => "describe this"}
      ]

      events = [event(:user, content: content)]
      assert Summary.from_events(events, @path).first_prompt_preview == "describe this"
    end

    test "first_prompt_preview is truncated to 140 chars" do
      long = String.duplicate("a", 200)
      events = [event(:user, content: long)]
      preview = Summary.from_events(events, @path).first_prompt_preview
      assert String.length(preview) == 140
    end

    test "captures ai_title from an ai-title event" do
      events = [
        event(:user, content: "do the thing"),
        event(:ai_title, ai_title: "Refactor the auth flow")
      ]

      assert Summary.from_events(events, @path).ai_title == "Refactor the auth flow"
    end

    test "ai_title is nil when no ai-title event is present" do
      events = [event(:user, content: "hi")]
      assert Summary.from_events(events, @path).ai_title == nil
    end

    test "skips slash-command first prompts when picking first_prompt_preview" do
      events = [
        event(:user,
          content: "<command-name>/clear</command-name>\n<command-args></command-args>"
        ),
        event(:user, content: "the actual question"),
        event(:assistant, content: [%{"type" => "text", "text" => "ok"}])
      ]

      assert Summary.from_events(events, @path).first_prompt_preview == "the actual question"
    end

    test "first_prompt_preview is nil when only slash-command prompts exist" do
      events = [
        event(:user, content: "<command-name>/clear</command-name>"),
        event(:user, content: "<command-name>/compact</command-name>")
      ]

      assert Summary.from_events(events, @path).first_prompt_preview == nil
    end

    test "later ai-title events overwrite earlier ones" do
      events = [
        event(:ai_title, ai_title: "first guess"),
        event(:user, content: "more context"),
        event(:ai_title, ai_title: "refined title")
      ]

      assert Summary.from_events(events, @path).ai_title == "refined title"
    end
  end
end
