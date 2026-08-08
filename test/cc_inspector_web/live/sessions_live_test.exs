defmodule CcInspectorWeb.SessionsLiveTest do
  # async: false — these tests sandbox :claude_projects_dir via Application config,
  # which is global to the BEAM. Sequential is safest.
  use CcInspectorWeb.ConnCase, async: false

  import CcInspector.SessionFixtures

  setup do
    {:ok, dir: sandbox_claude_dir!()}
  end

  test "renders an empty state when there are no sessions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "Sessions"
    assert html =~ "No local coding-agent sessions found yet"
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

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

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
    render_async(view)

    html = render_change(view, "filter", %{"q" => "alpha"})

    assert html =~ "alpha prompt"
    refute html =~ "beta prompt"
  end

  test "filter shows a no-match message when nothing matches", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha")
    ])

    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    html = render_change(view, "filter", %{"q" => "nothingmatches"})
    assert html =~ ~s|No sessions match|
    assert html =~ "nothingmatches"
  end

  test "provider pills filter the session stream", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "claude-only prompt", cwd: "/Users/me/proj/alpha")
    ])

    {:ok, view, _html} = live(conn, ~p"/")
    assert render_async(view) =~ "claude-only prompt"

    html = view |> element("#provider-filter-codex") |> render_click()
    refute html =~ "claude-only prompt"
    assert html =~ "No sessions match"

    html = view |> element("#provider-filter-all") |> render_click()
    assert html =~ "claude-only prompt"
  end

  test "PubSub session_created broadcast triggers a re-fetch", %{conn: conn, dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute render_async(view) =~ "later prompt"

    write_session!(dir, "-Users-me-proj-late", "sess-late", [
      user_row(content: "later prompt", cwd: "/Users/me/proj/late")
    ])

    Phoenix.PubSub.broadcast(
      CcInspector.PubSub,
      "sessions",
      {:session_changed, :claude, "sess-late", :created}
    )

    _ = render(view)
    assert render_async(view) =~ "later prompt"
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

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "Snappy AI title"
    assert html =~ "the user typed something verbose"
  end

  test "falls back to first_prompt when no ai_title is present", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-untitled", "sess-untitled", [
      user_row(content: "explain this", cwd: "/Users/me/proj/untitled")
    ])

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "explain this"
  end

  test "caps each project at 10 sessions and reveals the rest via the expander", %{
    conn: conn,
    dir: dir
  } do
    for i <- 1..12 do
      write_session!(dir, "-Users-me-proj-bigly", "sess-#{i}", [
        user_row(content: "prompt #{i}", cwd: "/Users/me/proj/bigly")
      ])
    end

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "Show 2 more sessions"

    html =
      view
      |> element(~s|button[phx-value-cwd="/Users/me/proj/bigly"]|)
      |> render_click()

    refute html =~ "Show 2 more sessions"
    assert html =~ "Show less"
  end

  test "links route to the session detail page", %{conn: conn, dir: dir} do
    write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
      user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha")
    ])

    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    assert view
           |> element(~s|a[href="/sessions/claude/sess-alpha"]|)
           |> has_element?()
  end

  describe "usage dashboard" do
    setup %{dir: dir} do
      write_session!(dir, "-Users-me-proj-alpha", "sess-alpha", [
        user_row(content: "alpha prompt", cwd: "/Users/me/proj/alpha"),
        assistant_row(
          message_id: "ma1",
          content: [text_block("ok")],
          usage: %{input: 500, output: 20, cache_read: 9_000, cache_creation: 100}
        )
      ])

      :ok
    end

    test "renders the stat cards and both charts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      for id <- ~w(stat-input stat-cached stat-output stat-total) do
        assert has_element?(view, "##{id}")
      end

      assert has_element?(view, "#chart-types")
      assert has_element?(view, "#chart-providers")
      assert has_element?(view, "#legend-types")
    end

    # A file event fires a scan roughly twice a second while a session is
    # running. Shimmering the cards on each one strobed numbers that were
    # already on screen, so the skeleton is only for having nothing to show.
    test "a background refresh leaves the values up instead of shimmering",
         %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#stat-input-value")
      refute has_element?(view, "#stat-input-skeleton")

      write_session!(dir, "-Users-me-proj-beta", "sess-beta", [
        user_row(content: "beta prompt", cwd: "/Users/me/proj/beta")
      ])

      send(view.pid, {:session_changed, :claude, "sess-beta", :updated})

      assert has_element?(view, "#stat-input-value")
      refute has_element?(view, "#stat-input-skeleton")

      render_async(view)

      assert has_element?(view, "#stat-input-value")
      refute has_element?(view, "#stat-input-skeleton")
    end

    test "cards report the totals the chart is built from", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      # 500 input + (9_000 + 100) cached + 20 output = 9_620 total
      assert html =~ "9.6K"
      assert html =~ "9.1K"
    end

    test "the collapse toggle hides the body and remembers the choice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#usage-dashboard-toggle[aria-expanded='true']")

      view |> element("#usage-dashboard-toggle") |> render_click()
      assert has_element?(view, "#usage-dashboard-toggle[aria-expanded='false']")

      view |> element("#usage-dashboard-toggle") |> render_click()
      assert has_element?(view, "#usage-dashboard-toggle[aria-expanded='true']")
    end

    test "restore_dashboard applies the browser's stored state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      render_hook(view, "restore_dashboard", %{"collapsed" => true})
      assert has_element?(view, "#usage-dashboard-toggle[aria-expanded='false']")
    end

    test "the legend toggles a series off and back on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      before = render(view)
      view |> element("#legend-types-cached") |> render_click()
      refute render(view) == before

      view |> element("#legend-types-cached") |> render_click()
      assert render(view) == before
    end

    test "reasoning is disabled when no visible provider reports it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      # Only Claude data here, and Claude never reports reasoning tokens.
      assert has_element?(view, "#legend-types-reasoning[disabled]")
    end

    test "the last remaining series cannot be toggled off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      for key <- ~w(cached output) do
        view |> element("#legend-types-#{key}") |> render_click()
      end

      # Input is the only toggleable series left, so clicking it is a no-op
      # rather than a chart with nothing in it.
      before = render(view)
      view |> element("#legend-types-input") |> render_click()

      assert render(view) == before
      assert has_element?(view, "#chart-types")
    end

    test "pinning a provider stands the provider chart down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#chart-providers")

      view |> element("#provider-filter-claude") |> render_click()
      refute has_element?(view, "#chart-providers")
      assert has_element?(view, "#chart-types")
    end

    test "the text filter does not reach the dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      render_change(view, "filter", %{"q" => "nothingmatches"})

      assert has_element?(view, "#chart-types")
      assert render(view) =~ "9.6K"
    end
  end
end
