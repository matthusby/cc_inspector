defmodule CcInspectorWeb.SessionsLive do
  use CcInspectorWeb, :live_view

  alias CcInspector.Sessions

  @sessions_per_project 10
  @seven_days_seconds 7 * 86_400
  # Fallback for sessions with no timestamped entries (nil last_activity_at),
  # so DateTime sorts don't crash. See Sessions.list_summaries/0.
  @epoch ~U[1970-01-01 00:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sessions.subscribe()

    {:ok,
     socket
     |> assign(:filter, "")
     |> assign(:provider_filter, "all")
     |> assign(:expanded_projects, MapSet.new())
     |> assign_summaries()}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:filter, q) |> refresh_groups()}
  end

  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    {:noreply, socket |> assign(:provider_filter, provider) |> refresh_groups()}
  end

  def handle_event("toggle_project", %{"cwd" => cwd}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_projects, cwd) do
        MapSet.delete(socket.assigns.expanded_projects, cwd)
      else
        MapSet.put(socket.assigns.expanded_projects, cwd)
      end

    {:noreply, socket |> assign(:expanded_projects, expanded) |> refresh_groups()}
  end

  @impl true
  def handle_info({:session_changed, _provider, _id, _action}, socket) do
    {:noreply, assign_summaries(socket)}
  end

  def handle_info({:provider_changed, _provider}, socket) do
    {:noreply, assign_summaries(socket)}
  end

  defp assign_summaries(socket) do
    summaries = Sessions.list_summaries()

    socket
    |> assign(:summaries, summaries)
    |> refresh_groups()
  end

  defp visible_summaries(summaries, q, provider_filter) do
    needle = String.downcase(q)

    Enum.filter(summaries, fn s ->
      provider_matches? =
        provider_filter == "all" or Atom.to_string(s.provider) == provider_filter

      text_matches? =
        q == "" or
          [s.project_cwd, s.session_id, s.first_prompt_preview, s.git_branch, s.ai_title]
          |> Enum.any?(fn val ->
            is_binary(val) and String.contains?(String.downcase(val), needle)
          end)

      provider_matches? and text_matches?
    end)
  end

  defp seven_day_totals(summaries) do
    cutoff = DateTime.add(DateTime.utc_now(), -@seven_days_seconds, :second)

    summaries
    |> Enum.filter(fn s ->
      s.last_activity_at && DateTime.compare(s.last_activity_at, cutoff) != :lt
    end)
    |> Enum.reduce(
      %{input: 0, cache_read: 0, cache_creation: 0, output: 0, reasoning: 0},
      fn s, acc ->
        %{
          input: acc.input + (s.tokens.input || 0),
          cache_read: acc.cache_read + (s.tokens.cache_read || 0),
          cache_creation: acc.cache_creation + (s.tokens.cache_creation || 0),
          output: acc.output + (s.tokens.output || 0),
          reasoning: acc.reasoning + Map.get(s.tokens, :reasoning, 0)
        }
      end
    )
  end

  defp grouped_summaries(summaries, filter, provider_filter) do
    summaries
    |> visible_summaries(filter, provider_filter)
    |> Enum.group_by(& &1.project_cwd)
    |> Enum.map(fn {cwd, sessions} ->
      sorted = Enum.sort_by(sessions, &(&1.last_activity_at || @epoch), {:desc, DateTime})

      %{
        id: :erlang.phash2(cwd),
        cwd: cwd,
        sessions: sorted,
        last_activity_at: hd(sorted).last_activity_at,
        total_turns: Enum.reduce(sorted, 0, &(&2 + (&1.turn_count || 0)))
      }
    end)
    |> Enum.sort_by(&(&1.last_activity_at || @epoch), {:desc, DateTime})
  end

  defp refresh_groups(socket) do
    visible =
      visible_summaries(
        socket.assigns.summaries,
        socket.assigns.filter,
        socket.assigns.provider_filter
      )

    provider_summaries =
      visible_summaries(socket.assigns.summaries, "", socket.assigns.provider_filter)

    groups = grouped_summaries(visible, "", "all")

    socket
    |> assign(:groups_empty?, groups == [])
    |> assign(:group_count, length(groups))
    |> assign(:visible_count, length(visible))
    |> assign(:totals_7d, seven_day_totals(provider_summaries))
    |> stream(:groups, groups,
      reset: true,
      dom_id: fn group -> "project-group-#{group.id}" end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <.token_card label="Input" value={@totals_7d.input} />
          <.token_card
            label="Cached"
            value={@totals_7d.cache_read}
            hint={"cache_creation: #{number(@totals_7d.cache_creation)}"}
          />
          <.token_card label="Output" value={@totals_7d.output} />
          <.token_card label="Reasoning" value={@totals_7d.reasoning} />
        </div>

        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content tracking-tight">Sessions</h1>
            <p class="text-sm text-base-content/60 mt-1">
              {@visible_count} session{plural_suffix(@visible_count)} across {@group_count} project{plural_suffix(
                @group_count
              )} from
              local Claude Code, Codex, and OpenCode data
            </p>
          </div>
          <form id="session-filter-form" phx-change="filter" class="w-64">
            <input
              id="session-filter-input"
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
          id="provider-filters"
          class="flex flex-wrap gap-2"
          role="group"
          aria-label="Provider filter"
        >
          <button
            :for={
              {value, label} <- [
                {"all", "All"},
                {"claude", "Claude Code"},
                {"codex", "Codex"},
                {"opencode", "OpenCode"}
              ]
            }
            id={"provider-filter-#{value}"}
            type="button"
            phx-click="filter_provider"
            phx-value-provider={value}
            class={[
              "rounded-full border px-3 py-1.5 text-xs font-medium transition-all duration-150",
              if(@provider_filter == value,
                do: "border-primary bg-primary text-primary-content shadow-sm",
                else:
                  "border-base-300 bg-base-100 text-base-content/60 hover:border-primary/50 hover:text-base-content"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <div id="session-groups" phx-update="stream" class="space-y-6">
          <div
            :if={@groups_empty?}
            id="sessions-empty-state"
            class="rounded-lg border border-base-300 bg-base-100 p-12 text-center text-base-content/40"
          >
            <%= if @summaries == [] do %>
              No local coding-agent sessions found yet.
            <% else %>
              No sessions match "{@filter}" with the current provider filter.
            <% end %>
          </div>
          <div :for={{id, group} <- @streams.groups} id={id}>
            <.project_card
              group={group}
              expanded={MapSet.member?(@expanded_projects, group.cwd)}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :hint, :string, default: nil

  defp token_card(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-base-300 bg-base-100 px-4 py-3"
      title={@hint}
    >
      <div class="text-xs uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="mt-1 text-xl font-semibold tabular-nums text-base-content">
        {number(@value)}
      </div>
      <div class="text-xs text-base-content/40 mt-0.5">tokens · last 7 days</div>
    </div>
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
              <.link
                navigate={~p"/sessions/#{Sessions.provider_slug(s.provider)}/#{s.session_id}"}
                class="block group min-w-0"
              >
                <div class="text-base-content/90 line-clamp-1 group-hover:text-primary">
                  {s.ai_title || s.first_prompt_preview || "(no prompt)"}
                </div>
                <div
                  :if={s.ai_title && s.first_prompt_preview}
                  class="text-xs text-base-content/50 line-clamp-1 mt-0.5"
                >
                  {s.first_prompt_preview}
                </div>
                <div class="text-xs text-base-content/40 font-mono mt-1 flex items-center gap-2">
                  <.provider_badge provider={s.provider} />
                  <span>{s.git_branch || s.model || "—"}</span>
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
                id={"toggle-project-#{@group.id}"}
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

  attr :provider, :atom, required: true

  defp provider_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      @provider == :claude && "bg-orange-500/10 text-orange-700 dark:text-orange-300",
      @provider == :codex && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
      @provider == :opencode && "bg-sky-500/10 text-sky-700 dark:text-sky-300"
    ]}>
      {Sessions.provider_label(@provider)}
    </span>
    """
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"
end
