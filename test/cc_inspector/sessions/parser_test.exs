defmodule CcInspector.Sessions.ParserTest do
  use ExUnit.Case, async: true

  import CcInspector.SessionFixtures

  alias CcInspector.Sessions.Parser
  alias CcInspector.Sessions.Parser.Event

  describe "parse_line/1" do
    test "parses an assistant row including message id, model, content, usage" do
      row =
        assistant_row(
          message_id: "msg_01",
          model: "claude-opus-4-7",
          content: [text_block("hello"), tool_use_block("Bash", %{"command" => "ls"})],
          usage: %{input: 10, output: 20, cache_read: 5, cache_creation: 1}
        )

      assert {:ok, %Event{} = ev} = Parser.parse_line(Jason.encode!(row))
      assert ev.type == :assistant
      assert ev.role == :assistant
      assert ev.message_id == "msg_01"
      assert ev.model == "claude-opus-4-7"
      assert ev.usage == %{input: 10, output: 20, cache_read: 5, cache_creation: 1}
      assert [%{"type" => "text"}, %{"type" => "tool_use"}] = ev.content
    end

    test "parses a user prompt with string content" do
      row = user_row(content: "ping")

      assert {:ok, %Event{type: :user, role: :user, content: "ping"}} =
               Parser.parse_line(Jason.encode!(row))
    end

    test "parses a user tool_result row with array content" do
      block = tool_result_block("toolu_1", "stdout")
      row = user_row(content: [block])

      assert {:ok, %Event{type: :user, content: [^block]}} =
               Parser.parse_line(Jason.encode!(row))
    end

    test "captures cwd, gitBranch, sessionId, version, parentUuid" do
      row =
        assistant_row(
          cwd: "/Users/me/proj",
          git_branch: "main",
          session_id: "sess-1",
          version: "1.0.99",
          parent_uuid: "parent-uuid"
        )

      assert {:ok, ev} = Parser.parse_line(Jason.encode!(row))
      assert ev.cwd == "/Users/me/proj"
      assert ev.git_branch == "main"
      assert ev.session_id == "sess-1"
      assert ev.version == "1.0.99"
      assert ev.parent_uuid == "parent-uuid"
    end

    test "isMeta and isSidechain are coerced to booleans" do
      row = user_row(is_meta: true, is_sidechain: true)

      assert {:ok, %Event{is_meta: true, is_sidechain: true}} =
               Parser.parse_line(Jason.encode!(row))

      row2 = user_row()

      assert {:ok, %Event{is_meta: false, is_sidechain: false}} =
               Parser.parse_line(Jason.encode!(row2))
    end

    test "parses ISO8601 timestamps to DateTime" do
      row = user_row(timestamp: "2026-04-29T12:34:56.000Z")

      assert {:ok, %Event{timestamp: %DateTime{} = dt}} = Parser.parse_line(Jason.encode!(row))
      assert dt.year == 2026 and dt.month == 4 and dt.day == 29
      assert dt.hour == 12 and dt.minute == 34 and dt.second == 56
    end

    test "missing timestamp is nil" do
      row = user_row() |> Map.delete("timestamp")

      assert {:ok, %Event{timestamp: nil}} = Parser.parse_line(Jason.encode!(row))
    end

    test "classifies the well-known meta row types" do
      classifications = [
        {system_row(), :system},
        {file_history_row(), :file_history},
        {attachment_row(), :attachment},
        {permission_mode_row(), :permission_mode},
        {queue_operation_row(), :queue_operation},
        {last_prompt_row(), :last_prompt},
        {ai_title_row("sess-1", "irrelevant"), :ai_title}
      ]

      for {row, expected} <- classifications do
        assert {:ok, %Event{type: ^expected}} = Parser.parse_line(Jason.encode!(row))
      end
    end

    test "captures aiTitle on ai-title rows" do
      row = ai_title_row("sess-1", "Refactor the auth flow")

      assert {:ok, %Event{type: :ai_title, ai_title: "Refactor the auth flow"}} =
               Parser.parse_line(Jason.encode!(row))
    end

    test "unknown string type becomes {:other, raw}" do
      row = base_row("widget")
      assert {:ok, %Event{type: {:other, "widget"}}} = Parser.parse_line(Jason.encode!(row))
    end

    test "missing type becomes :unknown" do
      row = %{"uuid" => "x"}
      assert {:ok, %Event{type: :unknown}} = Parser.parse_line(Jason.encode!(row))
    end

    test "raw is preserved on the event" do
      row = user_row(content: "keep me")
      assert {:ok, %Event{raw: ^row}} = Parser.parse_line(Jason.encode!(row))
    end

    test "usage with missing keys defaults to zero" do
      row =
        assistant_row()
        |> put_in(["message", "usage"], %{"input_tokens" => 5})

      assert {:ok, %Event{usage: %{input: 5, output: 0, cache_read: 0, cache_creation: 0}}} =
               Parser.parse_line(Jason.encode!(row))
    end

    test "no usage key yields nil usage" do
      row = assistant_row() |> update_in(["message"], &Map.delete(&1, "usage"))
      assert {:ok, %Event{usage: nil}} = Parser.parse_line(Jason.encode!(row))
    end

    test "returns a Jason error tuple on malformed JSON" do
      assert {:error, %Jason.DecodeError{}} = Parser.parse_line("{not json")
    end
  end

  describe "parse_file/1" do
    @tag :tmp_dir
    test "returns events in file order, skipping malformed and blank lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "session.jsonl")

      lines = [
        Jason.encode!(user_row(uuid: "u1", content: "first")),
        "",
        "{not valid json",
        Jason.encode!(assistant_row(uuid: "a1", message_id: "m1")),
        Jason.encode!(user_row(uuid: "u2", content: "second"))
      ]

      File.write!(path, Enum.join(lines, "\n") <> "\n")

      events = Parser.parse_file(path)

      assert Enum.map(events, & &1.uuid) == ["u1", "a1", "u2"]
      assert Enum.map(events, & &1.type) == [:user, :assistant, :user]
    end

    @tag :tmp_dir
    test "returns [] for an empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.jsonl")
      File.write!(path, "")
      assert Parser.parse_file(path) == []
    end
  end

  defp base_row(type) do
    %{
      "type" => type,
      "uuid" => uuid(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
