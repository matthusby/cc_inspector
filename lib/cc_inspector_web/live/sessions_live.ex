defmodule CcInspectorWeb.SessionsLive do
  use CcInspectorWeb, :live_view

  alias CcInspector.Sessions

  @sessions_per_project 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sessions.subscribe()

    {:ok,
     socket
     |> assign(:filter, "")
     |> assign(:expanded_projects, MapSet.new())
     |> assign_summaries()}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, :filter, q)}
  end

  def handle_event("toggle_project", %{"cwd" => cwd}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_projects, cwd) do
        MapSet.delete(socket.assigns.expanded_projects, cwd)
      else
        MapSet.put(socket.assigns.expanded_projects, cwd)
      end

    {:noreply, assign(socket, :expanded_projects, expanded)}
  end

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:session_created, :session_updated, :session_removed] do
    {:noreply, assign_summaries(socket)}
  end

  defp assign_summaries(socket) do
    assign(socket, :summaries, Sessions.list_summaries())
  end

  defp visible_summaries(summaries, ""), do: summaries

  defp visible_summaries(summaries, q) do
    needle = String.downcase(q)

    Enum.filter(summaries, fn s ->
      [s.project_cwd, s.session_id, s.first_prompt_preview, s.git_branch]
      |> Enum.any?(fn val ->
        is_binary(val) and String.contains?(String.downcase(val), needle)
      end)
    end)
  end

  defp grouped_summaries(summaries, filter) do
    summaries
    |> visible_summaries(filter)
    |> Enum.group_by(& &1.project_cwd)
    |> Enum.map(fn {cwd, sessions} ->
      sorted = Enum.sort_by(sessions, & &1.last_activity_at, {:desc, DateTime})

      %{
        cwd: cwd,
        sessions: sorted,
        last_activity_at: hd(sorted).last_activity_at,
        total_turns: Enum.reduce(sorted, 0, &(&2 + (&1.turn_count || 0)))
      }
    end)
    |> Enum.sort_by(& &1.last_activity_at, {:desc, DateTime})
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, grouped_summaries(assigns.summaries, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content tracking-tight">Sessions</h1>
            <p class="text-sm text-base-content/60 mt-1">
              {length(@summaries)} session{if length(@summaries) == 1, do: "", else: "s"} across {length(
                @groups
              )} project{if length(@groups) == 1, do: "", else: "s"} from
              <code class="text-xs px-1.5 py-0.5 rounded bg-base-200">
                {Sessions.claude_dir()}
              </code>
            </p>
          </div>
          <form phx-change="filter" class="w-64">
            <input
              type="text"
              name="q"
              value={@filter}
              placeholder="Filter projects, prompts, branches…"
              class="w-full px-3 py-1.5 text-sm rounded-md border border-base-300 bg-base-100 focus:outline-none focus:border-primary"
              phx-debounce="150"
            />
          </form>
        </div>

        <div
          :if={@groups == []}
          class="rounded-lg border border-base-300 bg-base-100 p-12 text-center text-base-content/40"
        >
          <%= if @summaries == [] do %>
            No Claude Code sessions found yet. Start a session and it'll appear here.
          <% else %>
            No sessions match "{@filter}".
          <% end %>
        </div>

        <.project_card
          :for={group <- @groups}
          group={group}
          expanded={MapSet.member?(@expanded_projects, group.cwd)}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :group, :map, required: true
  attr :expanded, :boolean, default: false

  defp project_card(assigns) do
    total = length(assigns.group.sessions)

    visible =
      if assigns.expanded,
        do: assigns.group.sessions,
        else: Enum.take(assigns.group.sessions, @sessions_per_project)

    assigns =
      assigns
      |> assign(:visible_sessions, visible)
      |> assign(:hidden_count, total - length(visible))

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 overflow-hidden">
      <header class="px-5 py-3 border-b border-base-300 flex items-baseline justify-between gap-4">
        <div class="min-w-0 flex items-baseline gap-3">
          <h2 class="font-semibold tracking-tight truncate">
            {project_name(@group.cwd)}
          </h2>
          <code class="text-xs text-base-content/50 font-mono truncate">{@group.cwd}</code>
        </div>
        <div class="text-xs text-base-content/50 shrink-0 tabular-nums flex gap-3">
          <span>
            {length(@group.sessions)} session{if length(@group.sessions) == 1, do: "", else: "s"}
          </span>
          <span>·</span>
          <span title={absolute_time(@group.last_activity_at)}>
            {relative_time(@group.last_activity_at)}
          </span>
        </div>
      </header>

      <table class="w-full text-sm">
        <thead class="bg-base-200/30 text-xs uppercase tracking-wide text-base-content/50">
          <tr>
            <th class="text-left px-4 py-2 font-medium">Title</th>
            <th class="text-right px-3 py-2 font-medium">When</th>
            <th class="text-right px-3 py-2 font-medium">Duration</th>
            <th class="text-right px-3 py-2 font-medium">Turns</th>
            <th class="text-right px-3 py-2 font-medium">Input</th>
            <th class="text-right px-3 py-2 font-medium">Cached</th>
            <th class="text-right px-3 py-2 font-medium">Output</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-base-200">
          <tr :for={s <- @visible_sessions} class="hover:bg-base-200/40 transition-colors">
            <td class="px-4 py-2.5 max-w-0 w-full">
              <.link navigate={~p"/sessions/#{s.session_id}"} class="block group min-w-0">
                <div class="text-base-content/90 line-clamp-1 group-hover:text-primary">
                  {s.ai_title || s.first_prompt_preview || "(no prompt)"}
                </div>
                <div
                  :if={s.ai_title && s.first_prompt_preview}
                  class="text-xs text-base-content/50 line-clamp-1 mt-0.5"
                >
                  {s.first_prompt_preview}
                </div>
                <div class="text-xs text-base-content/40 font-mono mt-0.5">
                  {s.git_branch || "—"}
                </div>
              </.link>
            </td>
            <td
              class="px-3 py-2.5 text-right text-xs text-base-content/60 tabular-nums whitespace-nowrap align-top"
              title={absolute_time(s.last_activity_at)}
            >
              {relative_time(s.last_activity_at)}
            </td>
            <td class="px-3 py-2.5 text-right text-xs text-base-content/60 tabular-nums whitespace-nowrap align-top">
              {duration(s.duration_ms)}
            </td>
            <td class="px-3 py-2.5 text-right text-xs text-base-content/70 tabular-nums align-top">
              {s.turn_count}
            </td>
            <td class="px-3 py-2.5 text-right text-xs text-base-content/70 tabular-nums align-top">
              {number(s.tokens.input)}
            </td>
            <td
              class="px-3 py-2.5 text-right text-xs text-base-content/50 tabular-nums align-top"
              title={"cache_creation: #{number(s.tokens.cache_creation)}"}
            >
              {number(s.tokens.cache_read)}
            </td>
            <td class="px-3 py-2.5 text-right text-xs text-base-content/70 tabular-nums align-top">
              {number(s.tokens.output)}
            </td>
          </tr>
          <tr :if={@hidden_count > 0 or @expanded}>
            <td colspan="7" class="px-4 py-2 text-center bg-base-200/20">
              <button
                type="button"
                phx-click="toggle_project"
                phx-value-cwd={@group.cwd}
                class="text-xs text-base-content/60 hover:text-primary transition-colors"
              >
                <%= if @expanded do %>
                  Show less
                <% else %>
                  Show {@hidden_count} more session{if @hidden_count == 1, do: "", else: "s"}
                <% end %>
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
