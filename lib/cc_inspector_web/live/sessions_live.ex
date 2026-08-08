defmodule CcInspectorWeb.SessionsLive do
  use CcInspectorWeb, :live_view

  import CcInspectorWeb.Dashboard

  alias CcInspector.Sessions
  alias CcInspector.Sessions.Dashboard

  @sessions_per_project 10
  # Fallback for sessions with no timestamped entries (nil last_activity_at),
  # so DateTime sorts don't crash. See Sessions.load/0.
  @epoch ~U[1970-01-01 00:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sessions.subscribe()

    socket =
      socket
      |> assign(:filter, "")
      |> assign(:provider_filter, "all")
      |> assign(:expanded_projects, MapSet.new())
      |> assign(:summaries, [])
      |> assign(:failed_providers, [])
      # `loading?` guards against overlapping scans; `loaded?` drives the
      # skeletons. They are separate because a file event fires a scan roughly
      # twice a second during an active session, and shimmering the cards on
      # every one of those strobes numbers that are already on screen. The
      # skeleton is for having nothing to show, not for being busy.
      |> assign(:loading?, false)
      |> assign(:loaded?, false)
      |> assign(:reload_queued?, false)
      |> assign(:dashboard_collapsed?, false)
      |> assign(:hidden_types, [])
      |> assign(:hidden_providers, [])
      |> assign(:dashboard, Dashboard.empty())
      |> refresh_groups()

    # A cold scan reads well over a gigabyte of JSONL. Loading it off the mount
    # means the page paints its shell and skeletons immediately instead of
    # holding a blank response open for several seconds.
    {:ok,
     if(connected?(socket), do: load_summaries(socket), else: assign(socket, :loading?, true))}
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

  def handle_event("toggle_dashboard", _params, socket) do
    collapsed = not socket.assigns.dashboard_collapsed?

    {:noreply,
     socket
     |> assign(:dashboard_collapsed?, collapsed)
     |> push_event("dashboard:collapsed", %{collapsed: collapsed})}
  end

  def handle_event("restore_dashboard", %{"collapsed" => collapsed}, socket) do
    {:noreply, assign(socket, :dashboard_collapsed?, collapsed == true)}
  end

  def handle_event("toggle_type", %{"key" => key}, socket) do
    toggleable = toggleable_types(socket)
    parsed = token_key(key)

    if parsed && parsed in toggleable do
      {:noreply, toggle_series(socket, :hidden_types, parsed, toggleable)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_provider", %{"key" => key}, socket) do
    available = Enum.map(socket.assigns.dashboard.by_provider, & &1.provider)

    case Sessions.parse_provider(key) do
      {:ok, provider} -> {:noreply, toggle_series(socket, :hidden_providers, provider, available)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:session_changed, _provider, _id, _action}, socket) do
    {:noreply, load_summaries(socket)}
  end

  def handle_info({:provider_changed, _provider}, socket) do
    {:noreply, load_summaries(socket)}
  end

  @impl true
  def handle_async(:summaries, {:ok, %{summaries: summaries, failed_providers: failed}}, socket) do
    socket =
      socket
      |> assign(:loading?, false)
      |> assign(:loaded?, true)
      |> assign(:summaries, summaries)
      |> assign(:failed_providers, failed)
      |> refresh_groups()

    if socket.assigns.reload_queued? do
      {:noreply, socket |> assign(:reload_queued?, false) |> load_summaries()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:summaries, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     # Stop the skeleton even though nothing arrived: shimmering forever reads
     # as "still working" when the truth is that the scan died.
     |> assign(:loaded?, true)
     |> assign(:reload_queued?, false)
     |> assign(:failed_providers, Sessions.enabled_providers())}
  end

  # Filesystem events arrive in bursts. Rather than spawn a scan per event,
  # queue at most one follow-up and run it when the in-flight scan lands.
  defp load_summaries(socket) do
    if socket.assigns.loading? do
      assign(socket, :reload_queued?, true)
    else
      socket
      |> assign(:loading?, true)
      |> start_async(:summaries, &Sessions.load/0)
    end
  end

  # Toggling the last visible series off would leave an empty chart that reads
  # as broken, so the final one stays on.
  defp toggle_series(socket, assign_key, value, available) do
    hidden = socket.assigns[assign_key]

    cond do
      value in hidden -> assign(socket, assign_key, List.delete(hidden, value))
      length(available) - length(hidden) <= 1 -> socket
      true -> assign(socket, assign_key, [value | hidden])
    end
  end

  # Reasoning is greyed out when no visible provider reports it, so it must not
  # count toward "series still showing" either — otherwise turning the others
  # off leaves a chart whose only enabled series can never have data.
  defp toggleable_types(socket) do
    if Enum.any?(socket.assigns.dashboard.by_provider, &Dashboard.reports_reasoning?(&1.provider)) do
      token_keys()
    else
      token_keys() -- [:reasoning]
    end
  end

  defp token_key("input"), do: :input
  defp token_key("cached"), do: :cached
  defp token_key("output"), do: :output
  defp token_key("reasoning"), do: :reasoning
  defp token_key(_), do: nil

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
    |> assign(:dashboard, Dashboard.build(provider_summaries))
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
        <.usage_dashboard
          dashboard={@dashboard}
          collapsed={@dashboard_collapsed?}
          loading={not @loaded?}
          failed_providers={@failed_providers}
          hidden_types={@hidden_types}
          hidden_providers={@hidden_providers}
          provider_filter={@provider_filter}
        />

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
