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

  describe "usage_from_rows/1" do
    test "groups the SQL rollup into per-session hourly buckets" do
      rows = [
        %{
          "session_id" => "a",
          "hour" => 100,
          "input" => 10,
          "output" => 2,
          "cache_read" => 5,
          "cache_creation" => 1,
          "reasoning" => 3
        },
        %{
          "session_id" => "a",
          "hour" => 101,
          "input" => 7,
          "output" => 1,
          "cache_read" => 0,
          "cache_creation" => 0,
          "reasoning" => 0
        },
        %{
          "session_id" => "b",
          "hour" => 100,
          "input" => 4,
          "output" => 0,
          "cache_read" => 0,
          "cache_creation" => 0,
          "reasoning" => 0
        }
      ]

      usage = OpenCodeParser.usage_from_rows(rows)

      assert Map.keys(usage) |> Enum.sort() == ["a", "b"]
      assert map_size(usage["a"]) == 2

      assert usage["a"][100] == %{
               input: 10,
               output: 2,
               cache_read: 5,
               cache_creation: 1,
               reasoning: 3
             }

      assert usage["a"][101].input == 7
      assert usage["b"][100].input == 4
    end

    test "sums rows that land in the same session and hour" do
      rows = [
        %{"session_id" => "a", "hour" => 100, "input" => 10},
        %{"session_id" => "a", "hour" => 100, "input" => 5}
      ]

      assert OpenCodeParser.usage_from_rows(rows)["a"][100].input == 15
    end

    test "tolerates nulls, floats, and malformed rows" do
      rows = [
        %{"session_id" => "a", "hour" => 100, "input" => nil, "output" => 3.0},
        %{"session_id" => nil, "hour" => 100, "input" => 99},
        %{"session_id" => "b", "hour" => nil, "input" => 99},
        %{"nonsense" => true}
      ]

      usage = OpenCodeParser.usage_from_rows(rows)

      assert Map.keys(usage) == ["a"]

      assert usage["a"][100] == %{
               input: 0,
               output: 3,
               cache_read: 0,
               cache_creation: 0,
               reasoning: 0
             }
    end

    test "returns an empty map for anything that isn't a list" do
      assert OpenCodeParser.usage_from_rows(nil) == %{}
    end
  end
end
