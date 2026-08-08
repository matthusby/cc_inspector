defmodule CcInspector.Sessions.CodexParserTest do
  use ExUnit.Case, async: true

  alias CcInspector.Sessions.CodexParser
  alias CcInspector.Sessions.Turns.Block
  alias CcInspector.Sessions.Usage

  setup do
    dir = Path.join(System.tmp_dir!(), "cc_inspector_codex_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "parses a current rollout into a summary and paired turn blocks", %{dir: dir} do
    id = "019f54aa-c5a7-7e10-ad9d-eae48bd376d9"
    path = Path.join(dir, "rollout-2026-07-12T00-00-00-#{id}.jsonl")

    rows = [
      row("session_meta", %{
        "id" => id,
        "session_id" => id,
        "timestamp" => "2026-07-12T00:00:00Z",
        "cwd" => "/Users/me/project",
        "cli_version" => "0.144.1",
        "source" => "cli",
        "git" => %{"branch" => "main"}
      }),
      row("response_item", %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "injected context"}]
      }),
      row("event_msg", %{"type" => "user_message", "message" => "Fix the parser"}),
      row("turn_context", %{"turn_id" => "turn-1", "model" => "gpt-5.6-sol"}),
      row("response_item", %{
        "type" => "reasoning",
        "summary" => [%{"type" => "summary_text", "text" => "Inspect the format"}]
      }),
      row("response_item", %{
        "type" => "custom_tool_call",
        "call_id" => "call-1",
        "name" => "shell_command",
        "input" => Jason.encode!(%{"command" => "mix test"})
      }),
      row("response_item", %{
        "type" => "custom_tool_call_output",
        "call_id" => "call-1",
        "output" => "all green"
      }),
      row("response_item", %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "Fixed."}]
      }),
      row("event_msg", %{
        "type" => "token_count",
        "info" => %{
          "last_token_usage" => token_usage(100, 20, 80, 5),
          "total_token_usage" => token_usage(100, 20, 80, 5)
        }
      })
    ]

    write_jsonl!(path, rows)
    document = CodexParser.parse_file(path)

    assert document.source == "cli"
    assert document.summary.provider == :codex
    assert document.summary.session_id == id
    assert document.summary.project_cwd == "/Users/me/project"
    assert document.summary.git_branch == "main"
    assert document.summary.model == "gpt-5.6-sol"
    assert document.summary.turn_count == 1
    assert document.summary.tool_call_count == 1

    assert document.summary.tokens == %{
             input: 100,
             output: 20,
             cache_read: 80,
             cache_creation: 0,
             reasoning: 5
           }

    assert [turn] = document.turns
    assert turn.id == "turn-1"
    assert turn.user_text == "Fix the parser"
    assert Enum.any?(turn.blocks, &match?(%Block{kind: :thinking}, &1))
    assert Enum.any?(turn.blocks, &match?(%Block{kind: :text}, &1))

    assert %Block{data: %{result: %{content: "all green"}}} =
             Enum.find(turn.blocks, &match?(%Block{kind: :tool_use}, &1))
  end

  test "parses legacy JSON sessions", %{dir: dir} do
    path = Path.join(dir, "rollout-legacy-id.json")

    File.write!(
      path,
      Jason.encode!(%{
        "session" => %{"id" => "legacy-id", "timestamp" => "2025-05-17T12:00:00Z"},
        "items" => [
          %{"type" => "message", "role" => "user", "content" => "Legacy prompt"},
          %{"type" => "message", "role" => "assistant", "content" => "Legacy answer"}
        ]
      })
    )

    document = CodexParser.parse_file(path)

    assert document.summary.session_id == "legacy-id"
    assert document.summary.turn_count == 1
    assert [turn] = document.turns
    assert turn.user_text == "Legacy prompt"
    assert [%Block{kind: :text, data: %{text: "Legacy answer"}}] = turn.blocks
  end

  test "accumulates every token_count row into the turn instead of keeping the last", %{dir: dir} do
    id = "019f54aa-c5a7-7e10-ad9d-eae48bd376aa"
    path = Path.join(dir, "rollout-2026-07-12T00-00-00-#{id}.jsonl")

    # A turn emits one token_count per model request. Keeping only the last one
    # undercounted every multi-request turn by however many requests it took.
    rows =
      [
        row("session_meta", %{"id" => id, "timestamp" => "2026-07-12T00:00:00Z", "cwd" => "/p"}),
        row("event_msg", %{"type" => "user_message", "message" => "Do the thing"}),
        row("event_msg", %{
          "type" => "token_count",
          "info" => %{"last_token_usage" => token_usage(100, 10, 50, 1)}
        }),
        row("event_msg", %{
          "type" => "token_count",
          "info" => %{"last_token_usage" => token_usage(200, 20, 70, 2)}
        }),
        row("event_msg", %{
          "type" => "token_count",
          "info" => %{"last_token_usage" => token_usage(300, 30, 90, 3)}
        })
      ]

    write_jsonl!(path, rows)
    document = CodexParser.parse_file(path)

    assert [turn] = document.turns

    assert turn.tokens == %{
             input: 600,
             output: 60,
             cache_read: 210,
             cache_creation: 0,
             reasoning: 6
           }

    # With no total_token_usage row, the summary falls back to summing turns,
    # which is only correct once the turns themselves are.
    assert document.summary.tokens.input == 600
    assert document.summary.tokens.reasoning == 6
  end

  test "buckets token_count rows into the hour they were reported", %{dir: dir} do
    id = "019f54aa-c5a7-7e10-ad9d-eae48bd376bb"
    path = Path.join(dir, "rollout-2026-07-12T00-00-00-#{id}.jsonl")

    rows = [
      row("session_meta", %{"id" => id, "timestamp" => "2026-07-12T00:00:00Z", "cwd" => "/p"}),
      row("event_msg", %{"type" => "user_message", "message" => "go"}),
      at_time("2026-07-12T09:10:00Z", "event_msg", %{
        "type" => "token_count",
        "info" => %{"last_token_usage" => token_usage(10, 1, 0, 0)}
      }),
      at_time("2026-07-12T09:50:00Z", "event_msg", %{
        "type" => "token_count",
        "info" => %{"last_token_usage" => token_usage(20, 2, 0, 0)}
      }),
      at_time("2026-07-12T11:00:00Z", "event_msg", %{
        "type" => "token_count",
        "info" => %{"last_token_usage" => token_usage(5, 5, 0, 0)}
      })
    ]

    write_jsonl!(path, rows)
    document = CodexParser.parse_file(path)

    nine = Usage.hour_key(~U[2026-07-12 09:00:00Z])
    eleven = Usage.hour_key(~U[2026-07-12 11:00:00Z])

    assert map_size(document.summary.usage) == 2
    assert document.summary.usage[nine].input == 30
    assert document.summary.usage[nine].output == 3
    assert document.summary.usage[eleven].input == 5
  end

  defp row(type, payload) do
    at_time("2026-07-12T00:00:01Z", type, payload)
  end

  defp at_time(timestamp, type, payload) do
    %{"timestamp" => timestamp, "type" => type, "payload" => payload}
  end

  defp token_usage(input, output, cached, reasoning) do
    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "cached_input_tokens" => cached,
      "reasoning_output_tokens" => reasoning,
      "total_tokens" => input + output
    }
  end

  defp write_jsonl!(path, rows) do
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
  end
end
