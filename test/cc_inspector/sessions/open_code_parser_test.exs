defmodule CcInspector.Sessions.OpenCodeParserTest do
  use ExUnit.Case, async: true

  alias CcInspector.Sessions.OpenCodeParser
  alias CcInspector.Sessions.Turns.Block

  test "builds a provider-neutral summary from an OpenCode database row" do
    summary =
      OpenCodeParser.summary_from_row(%{
        "id" => "ses_123",
        "directory" => "/Users/me/project",
        "title" => "Repair authentication",
        "version" => "1.17.16",
        "time_created" => 1_752_307_200_000,
        "time_updated" => 1_752_307_260_000,
        "cost" => 1.25,
        "tokens_input" => 100,
        "tokens_output" => 20,
        "tokens_reasoning" => 5,
        "tokens_cache_read" => 80,
        "tokens_cache_write" => 10,
        "model" => "gpt-5.6",
        "user_message_count" => 2,
        "assistant_message_count" => 3,
        "tool_call_count" => 4,
        "first_prompt" => "Please repair authentication"
      })

    assert summary.provider == :opencode
    assert summary.session_id == "ses_123"
    assert summary.turn_count == 2
    assert summary.tool_call_count == 4
    assert summary.cost == 1.25
    assert summary.tokens.reasoning == 5
    assert summary.ai_title == "Repair authentication"
  end

  test "folds exported messages into turns with reasoning and completed tools" do
    export = %{
      "messages" => [
        %{
          "info" => %{
            "id" => "user-1",
            "role" => "user",
            "time" => %{"created" => 1_752_307_200_000}
          },
          "parts" => [%{"type" => "text", "text" => "Run the tests"}]
        },
        %{
          "info" => %{
            "id" => "assistant-1",
            "role" => "assistant",
            "providerID" => "openai",
            "modelID" => "gpt-5.6",
            "time" => %{
              "created" => 1_752_307_201_000,
              "completed" => 1_752_307_205_000
            },
            "cost" => 0.5,
            "tokens" => %{
              "input" => 10,
              "output" => 3,
              "reasoning" => 2,
              "cache" => %{"read" => 8, "write" => 1}
            }
          },
          "parts" => [
            %{"type" => "reasoning", "text" => "I should execute the suite"},
            %{
              "type" => "tool",
              "id" => "part-1",
              "callID" => "call-1",
              "tool" => "bash",
              "state" => %{
                "status" => "completed",
                "input" => %{"command" => "mix test"},
                "output" => "80 tests, 0 failures"
              }
            },
            %{"type" => "text", "text" => "Everything passes."}
          ]
        }
      ]
    }

    assert [turn] = OpenCodeParser.turns_from_export(export)
    assert turn.user_text == "Run the tests"
    assert turn.model == "openai/gpt-5.6"
    assert turn.cost == 0.5
    assert turn.tokens.reasoning == 2
    assert Enum.any?(turn.blocks, &match?(%Block{kind: :thinking}, &1))
    assert Enum.any?(turn.blocks, &match?(%Block{kind: :text}, &1))

    assert %Block{data: %{result: %{content: "80 tests, 0 failures"}}} =
             Enum.find(turn.blocks, &match?(%Block{kind: :tool_use}, &1))
  end
end
