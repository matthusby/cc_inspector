defmodule CcInspectorWeb.SessionsLiveTest do
  # async: false — these tests sandbox :claude_projects_dir via Application config,
  # which is global to the BEAM. Sequential is safest.
  use CcInspectorWeb.ConnCase, async: false

  import CcInspector.SessionFixtures

  setup do
    {:ok, dir: sandbox_claude_dir!()}
  end

  test "renders an empty state when there are no sessions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Sessions"
    assert html =~ "No Claude Code sessions found yet"
  end

  test "renders one row per session and shows the project + first prompt", %{
    conn: conn,
    dir: dir
  } do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "explain the auth flow", git_branch: "main", cwd: "/Users/me/proj/alpha"),
      assistant_row(message_id: "ma1", content: [text_block("here goes...")])
    ])

    write_session!(dir, "-Users-me-proj-beta", "sess-beta", [
      user_row(
        content: "fix the failing tests",
        git_branch: "fix/tests",
        cwd: "/Users/me/proj/beta"
      ),
      assistant_row(message_id: "mb1", content: [text_block("on it")])
    ])

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "explain the auth flow"
    assert html =~ "fix the failing tests"
    assert html =~ "main"
    assert html =~ "fix/tests"
  end

  test "filtering narrows the visible rows", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha")
    ])

    write_session!(dir, "-Users-me-proj-beta", "sess-beta", [
      user_row(content: "beta prompt", cwd: "/Users/me/proj/beta")
    ])

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_change(view, "filter", %{"q" => "alpha"})

    assert html =~ "alpha prompt"
    refute html =~ "beta prompt"
  end

  test "filter shows a no-match message when nothing matches", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha")
    ])

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_change(view, "filter", %{"q" => "nothingmatches"})
    assert html =~ ~s|No sessions match|
    assert html =~ "nothingmatches"
  end

  test "PubSub session_created broadcast triggers a re-fetch", %{conn: conn, dir: dir} do
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "later prompt"

    write_session!(dir, "-Users-me-proj-late", "sess-late", [
      user_row(content: "later prompt", cwd: "/Users/me/proj/late")
    ])

    Phoenix.PubSub.broadcast(CcInspector.PubSub, "sessions", {:session_created, "sess-late"})

    html = render(view)
    assert html =~ "later prompt"
  end

  test "shows ai_title as the row lead with first_prompt as a secondary line", %{
    conn: conn,
    dir: dir
  } do
    write_session!(dir, "-Users-me-proj-titled", "sess-titled", [
      user_row(content: "the user typed something verbose", cwd: "/Users/me/proj/titled"),
      assistant_row(message_id: "m1", content: [text_block("ok")]),
      ai_title_row("sess-titled", "Snappy AI title")
    ])

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Snappy AI title"
    assert html =~ "the user typed something verbose"
  end

  test "falls back to first_prompt when no ai_title is present", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-untitled", "sess-untitled", [
      user_row(content: "explain this", cwd: "/Users/me/proj/untitled")
    ])

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "explain this"
  end

  test "links route to the session detail page", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha")
    ])

    {:ok, view, _html} = live(conn, ~p"/")

    assert view
           |> element(~s|a[href="/sessions/sess-alpha"]|)
           |> has_element?()
  end
end
