defmodule CcInspectorWeb.SessionLiveTest do
  use CcInspectorWeb.ConnCase, async: false

  import CcInspector.SessionFixtures

  setup do
    {:ok, dir: sandbox_claude_dir!()}
  end

  test "redirects with a flash error when the session id is unknown", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => msg}}}} =
             live(conn, ~p"/sessions/does-not-exist")

    assert msg =~ "not found"
  end

  test "renders the session header with project, cwd, branch, and model", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-myproj", "sess-1", [
      user_row(
        content: "first prompt",
        cwd: "/Users/me/myproj",
        git_branch: "main"
      ),
      assistant_row(
        message_id: "m1",
        model: "claude-opus-4-7",
        content: [text_block("hi")]
      )
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-1")

    assert html =~ "myproj"
    assert html =~ "/Users/me/myproj"
    assert html =~ "main"
    assert html =~ "claude-opus-4-7"
    assert html =~ "sess-1"
  end

  test "shows ai_title as a subtitle in the header when present", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj", "sess-titled", [
      user_row(content: "go", cwd: "/Users/me/proj"),
      assistant_row(message_id: "m1", content: [text_block("ok")]),
      ai_title_row("sess-titled", "Refactor the auth flow")
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-titled")

    assert html =~ "Refactor the auth flow"
  end

  test "renders a turn with text, thinking, and a paired tool_use+result", %{
    conn: conn,
    dir: dir
  } do
    write_session!(dir, "-Users-me-proj", "sess-blocks", [
      user_row(content: "do the thing", cwd: "/Users/me/proj"),
      assistant_row(
        message_id: "m1",
        content: [
          thinking_block("hmm let me think"),
          text_block("I'll run a command."),
          tool_use_block("Bash", %{"command" => "echo hello"}, id: "tool_1")
        ]
      ),
      user_row(content: [tool_result_block("tool_1", "hello\n")]),
      assistant_row(
        message_id: "m2",
        content: [text_block("All done.")]
      )
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-blocks")

    assert html =~ "do the thing"
    assert html =~ "I&#39;ll run a command."
    assert html =~ "All done."
    assert html =~ "hmm let me think"
    assert html =~ "Bash"
    # tool_use input pretty-printed somewhere on the page
    assert html =~ "echo hello"
    # tool_result content visible
    assert html =~ "hello"
  end

  test "renders a slash command turn with the command name", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj", "sess-slash", [
      user_row(
        content: "<command-name>compact</command-name>\n<args>foo</args>",
        cwd: "/Users/me/proj"
      ),
      assistant_row(message_id: "m1", content: [text_block("done")])
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-slash")

    assert html =~ "compact"
    assert html =~ "done"
  end

  test "renders encrypted thinking pill (no expander) when thinking text is empty", %{
    conn: conn,
    dir: dir
  } do
    write_session!(dir, "-Users-me-proj", "sess-redacted", [
      user_row(content: "go", cwd: "/Users/me/proj"),
      assistant_row(
        message_id: "m1",
        content: [
          thinking_block(""),
          text_block("here's the answer")
        ]
      )
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-redacted")

    assert html =~ "thinking · encrypted"
    assert html =~ "here&#39;s the answer"

    # No <details> tag for the empty thinking block — only thinking-related
    # markup should be the pill.
    refute html =~ ~r{<details[^>]*>\s*<summary[^>]*>\s*<!--[^-]*-->\s*<span[^>]*hero-light-bulb}
  end

  test "renders thinking expander when thinking text is present", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj", "sess-thinking", [
      user_row(content: "go", cwd: "/Users/me/proj"),
      assistant_row(
        message_id: "m1",
        content: [
          thinking_block("the user wants X, so I should Y"),
          text_block("done")
        ]
      )
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-thinking")

    assert html =~ "the user wants X, so I should Y"
    refute html =~ "thinking · encrypted"
  end

  test "marks an errored tool result as an error", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj", "sess-err", [
      user_row(content: "go", cwd: "/Users/me/proj"),
      assistant_row(
        message_id: "m1",
        content: [tool_use_block("Bash", %{"command" => "false"}, id: "tool_e")]
      ),
      user_row(content: [tool_result_block("tool_e", "boom", is_error: true)])
    ])

    {:ok, view, _html} = live(conn, ~p"/sessions/sess-err")
    html = render(view)

    assert html =~ "error"
    assert html =~ "boom"
  end

  test "shows a collapsed summary of the assistant blocks per turn", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj", "sess-counts", [
      user_row(content: "do stuff", cwd: "/Users/me/proj"),
      assistant_row(
        message_id: "m1",
        content: [
          thinking_block("hmm"),
          text_block("first"),
          tool_use_block("Bash", %{"command" => "ls"}, id: "t1"),
          tool_use_block("Read", %{"file_path" => "/x"}, id: "t2"),
          text_block("second")
        ]
      )
    ])

    {:ok, _view, html} = live(conn, ~p"/sessions/sess-counts")

    assert html =~ "2 tools · 2 messages · 1 thinking block"
  end

  test "browses a local Codex rollout through the provider-aware route", %{conn: conn} do
    id = "019f54aa-c5a7-7e10-ad9d-eae48bd376d9"

    home =
      Path.join(
        System.tmp_dir!(),
        "cc_inspector_codex_live_#{System.unique_integer([:positive])}"
      )

    session_dir = Path.join([home, "sessions", "2026", "07", "12"])
    File.mkdir_p!(session_dir)

    previous_home = Application.get_env(:cc_inspector, :codex_home)
    previous_providers = Application.get_env(:cc_inspector, :session_providers)
    Application.put_env(:cc_inspector, :codex_home, home)
    Application.put_env(:cc_inspector, :session_providers, [:claude, :codex])

    on_exit(fn ->
      Application.put_env(:cc_inspector, :codex_home, previous_home)
      Application.put_env(:cc_inspector, :session_providers, previous_providers)
      File.rm_rf!(home)
    end)

    rows = [
      %{
        "timestamp" => "2026-07-12T00:00:00Z",
        "type" => "session_meta",
        "payload" => %{
          "id" => id,
          "session_id" => id,
          "timestamp" => "2026-07-12T00:00:00Z",
          "cwd" => "/Users/me/codex-project",
          "cli_version" => "0.144.1",
          "source" => "cli"
        }
      },
      %{
        "timestamp" => "2026-07-12T00:00:01Z",
        "type" => "event_msg",
        "payload" => %{"type" => "user_message", "message" => "Inspect local Codex data"}
      },
      %{
        "timestamp" => "2026-07-12T00:00:02Z",
        "type" => "turn_context",
        "payload" => %{"turn_id" => "turn-1", "model" => "gpt-5.6-sol"}
      },
      %{
        "timestamp" => "2026-07-12T00:00:03Z",
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Local rollout loaded."}]
        }
      }
    ]

    path = Path.join(session_dir, "rollout-2026-07-12T00-00-00-#{id}.jsonl")
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")

    {:ok, view, _html} = live(conn, ~p"/sessions/codex/#{id}")

    assert has_element?(view, "#session-turns")
    assert render(view) =~ "Codex"
    assert render(view) =~ "Inspect local Codex data"
    assert render(view) =~ "Local rollout loaded."
  end

  test "PubSub update on the session topic re-fetches turns", %{conn: conn, dir: dir} do
    path =
      write_session!(dir, "-Users-me-proj", "sess-live", [
        user_row(content: "first", cwd: "/Users/me/proj"),
        assistant_row(message_id: "m1", content: [text_block("hi")])
      ])

    {:ok, view, html} = live(conn, ~p"/sessions/sess-live")
    refute html =~ "second prompt"

    append_session!(path, [
      user_row(content: "second prompt"),
      assistant_row(message_id: "m2", content: [text_block("there")])
    ])

    # Mtime resolution can be coarse — bump it explicitly so the cache invalidates.
    File.touch!(path, {{2030, 1, 1}, {0, 0, 0}})

    Phoenix.PubSub.broadcast(
      CcInspector.PubSub,
      "session:claude:sess-live",
      {:session_changed, :claude, "sess-live", :updated}
    )

    html = render(view)
    assert html =~ "second prompt"
  end
end
