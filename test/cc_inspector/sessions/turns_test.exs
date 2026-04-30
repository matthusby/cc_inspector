defmodule CcInspector.Sessions.TurnsTest do
  use ExUnit.Case, async: true

  import CcInspector.SessionFixtures

  alias CcInspector.Sessions.Turns
  alias CcInspector.Sessions.Turns.{Block, Turn}

  describe "from_events/1" do
    test "groups assistant cascade and tool_result delivery into one turn" do
      events = [
        event(:user, content: "do the thing"),
        event(:assistant,
          content: [
            %{"type" => "thinking", "thinking" => "let me think"},
            %{"type" => "text", "text" => "I'll run a command."},
            %{
              "type" => "tool_use",
              "id" => "tool_1",
              "name" => "Bash",
              "input" => %{"command" => "ls"}
            }
          ]
        ),
        # tool_result delivery (a "user" event but not a new turn)
        event(:user,
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tool_1",
              "content" => "file1\nfile2",
              "is_error" => false
            }
          ]
        ),
        event(:assistant, content: [%{"type" => "text", "text" => "All done."}])
      ]

      assert [%Turn{} = turn] = Turns.from_events(events)
      assert turn.index == 1
      assert turn.user_kind == :prompt
      assert turn.user_text == "do the thing"

      kinds = Enum.map(turn.blocks, & &1.kind)
      assert kinds == [:thinking, :text, :tool_use, :text]
    end

    test "pairs each tool_use with its matching tool_result and drops standalone results" do
      events = [
        event(:user, content: "go"),
        event(:assistant,
          content: [
            %{
              "type" => "tool_use",
              "id" => "tool_a",
              "name" => "Read",
              "input" => %{"file_path" => "/x"}
            },
            %{
              "type" => "tool_use",
              "id" => "tool_b",
              "name" => "Bash",
              "input" => %{"command" => "true"}
            }
          ]
        ),
        event(:user,
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tool_a",
              "content" => "contents",
              "is_error" => false
            },
            %{
              "type" => "tool_result",
              "tool_use_id" => "tool_b",
              "content" => "boom",
              "is_error" => true
            }
          ]
        )
      ]

      [%Turn{blocks: blocks}] = Turns.from_events(events)

      # Only the tool_use blocks remain — tool_results were folded in
      assert Enum.all?(blocks, &(&1.kind == :tool_use))
      assert length(blocks) == 2

      [%Block{data: a}, %Block{data: b}] = blocks
      assert a.id == "tool_a"
      assert a.result.tool_use_id == "tool_a"
      assert a.result.is_error == false
      assert a.result.content == "contents"

      assert b.id == "tool_b"
      assert b.result.is_error == true
      assert b.result.content == "boom"
    end

    test "tool_use without a matching result has nil result" do
      events = [
        event(:user, content: "go"),
        event(:assistant,
          content: [
            %{"type" => "tool_use", "id" => "tool_x", "name" => "Bash", "input" => %{}}
          ]
        )
      ]

      [%Turn{blocks: [%Block{kind: :tool_use, data: data}]}] = Turns.from_events(events)
      assert data.id == "tool_x"
      assert data.result == nil
    end

    test "produces multiple turns indexed in order" do
      events = [
        event(:user, content: "first"),
        event(:assistant, content: [%{"type" => "text", "text" => "1"}]),
        event(:user, content: "second"),
        event(:assistant, content: [%{"type" => "text", "text" => "2"}]),
        event(:user, content: "third"),
        event(:assistant, content: [%{"type" => "text", "text" => "3"}])
      ]

      turns = Turns.from_events(events)
      assert Enum.map(turns, & &1.index) == [1, 2, 3]
      assert Enum.map(turns, & &1.user_text) == ["first", "second", "third"]
    end

    test "classifies <command-name>...</command-name> as :slash_command" do
      events = [
        event(:user, content: "<command-name>compact</command-name>\n<args>foo</args>")
      ]

      [%Turn{user_kind: :slash_command, user_text: "compact"}] = Turns.from_events(events)
    end

    test "list-style user content is classified as :prompt with extracted text" do
      events = [
        event(:user,
          content: [
            %{"type" => "image", "source" => "..."},
            %{"type" => "text", "text" => "describe"}
          ]
        )
      ]

      [%Turn{user_kind: :prompt, user_text: "describe"}] = Turns.from_events(events)
    end

    test "skips meta events, file-history, attachments, system, etc." do
      events = [
        event(:file_history, content: "snapshot"),
        event(:attachment),
        event(:system, content: "system note"),
        event(:permission_mode),
        event(:queue_operation),
        event(:last_prompt),
        event(:user, is_meta: true, content: "ignored"),
        event(:user, content: "real prompt"),
        event(:assistant, content: [%{"type" => "text", "text" => "ok"}])
      ]

      assert [%Turn{user_text: "real prompt"}] = Turns.from_events(events)
    end

    test "drops orphan assistant events that arrive before any user prompt" do
      events = [
        event(:assistant, content: [%{"type" => "text", "text" => "stray"}]),
        event(:user, content: "hi"),
        event(:assistant, content: [%{"type" => "text", "text" => "hello"}])
      ]

      assert [%Turn{blocks: [%Block{kind: :text, data: %{text: "hello"}}]}] =
               Turns.from_events(events)
    end

    test "dedupes per-turn token usage by message_id" do
      usage = usage(input: 100, output: 50, cache_read: 10, cache_creation: 1)

      events = [
        event(:user, content: "go"),
        event(:assistant, message_id: "msg_1", usage: usage, content: []),
        event(:assistant, message_id: "msg_1", usage: usage, content: []),
        event(:assistant,
          message_id: "msg_2",
          usage: usage(input: 5, output: 5),
          content: []
        )
      ]

      [%Turn{tokens: tokens}] = Turns.from_events(events)
      assert tokens.input == 105
      assert tokens.output == 55
      assert tokens.cache_read == 10
      assert tokens.cache_creation == 1
    end

    test "captures the assistant model on the turn" do
      events = [
        event(:user, content: "go"),
        event(:assistant,
          model: "claude-opus-4-7",
          content: [%{"type" => "text", "text" => "ok"}]
        )
      ]

      assert [%Turn{model: "claude-opus-4-7"}] = Turns.from_events(events)
    end

    test "ended_at advances to the latest event timestamp in the turn" do
      t1 = ~U[2026-04-29 12:00:00Z]
      t2 = ~U[2026-04-29 12:00:02Z]
      t3 = ~U[2026-04-29 12:00:05Z]

      events = [
        event(:user, timestamp: t1, content: "go"),
        event(:assistant,
          timestamp: t2,
          content: [%{"type" => "tool_use", "id" => "t", "name" => "Bash", "input" => %{}}]
        ),
        event(:user,
          timestamp: t3,
          content: [%{"type" => "tool_result", "tool_use_id" => "t", "content" => "ok"}]
        )
      ]

      [%Turn{started_at: ^t1, ended_at: ^t3}] = Turns.from_events(events)
    end

    test "unknown block types fall through as :unknown blocks" do
      events = [
        event(:user, content: "go"),
        event(:assistant, content: [%{"type" => "wat", "extra" => "data"}])
      ]

      [%Turn{blocks: [%Block{kind: :unknown, data: %{"type" => "wat"}}]}] =
        Turns.from_events(events)
    end
  end
end
