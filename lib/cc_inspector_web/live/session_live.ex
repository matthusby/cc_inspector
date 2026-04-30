defmodule CcInspectorWeb.SessionLive do
  use CcInspectorWeb, :live_view

  alias CcInspector.Sessions

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Sessions.subscribe(id)

    case Sessions.get_summary(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found.")
         |> push_navigate(to: ~p"/")}

      summary ->
        {:ok,
         socket
         |> assign(:session_id, id)
         |> assign(:summary, summary)
         |> assign(:turns, Sessions.get_turns(id) || [])}
    end
  end

  @impl true
  def handle_info({:session_updated, id}, %{assigns: %{session_id: id}} = socket) do
    {:noreply,
     socket
     |> assign(:summary, Sessions.get_summary(id))
     |> assign(:turns, Sessions.get_turns(id) || [])}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <.session_header summary={@summary} />
        <div class="space-y-8">
          <.turn_card :for={turn <- @turns} turn={turn} />
          <p :if={@turns == []} class="text-center text-base-content/40 py-12">
            No turns recorded yet.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true

  defp session_header(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div class="space-y-1 min-w-0">
          <.link navigate={~p"/"} class="text-xs text-base-content/50 hover:text-base-content">
            ← All sessions
          </.link>
          <h1 class="text-xl font-semibold tracking-tight truncate">
            {project_name(@summary.project_cwd)}
          </h1>
          <div :if={@summary.ai_title} class="text-sm text-base-content/80 truncate">
            {@summary.ai_title}
          </div>
          <div class="text-xs text-base-content/50 font-mono truncate">
            {@summary.project_cwd} · {@summary.git_branch || "—"}
          </div>
        </div>
        <div class="flex flex-col items-end gap-1 shrink-0">
          <span class="text-xs font-mono text-base-content/40">{@summary.session_id}</span>
          <span
            :if={@summary.model}
            class="text-xs px-2 py-0.5 rounded-full bg-base-200 text-base-content/70"
          >
            {@summary.model}
          </span>
        </div>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-3 text-sm">
        <.stat label="Turns" value={@summary.turn_count} />
        <.stat label="Tool calls" value={@summary.tool_call_count} />
        <.stat label="Input" value={number(@summary.tokens.input)} />
        <.stat label="Cached read" value={number(@summary.tokens.cache_read)} />
        <.stat label="Cache write" value={number(@summary.tokens.cache_creation)} />
        <.stat label="Output" value={number(@summary.tokens.output)} />
        <.stat label="Duration" value={duration(@summary.duration_ms)} />
      </div>

      <div class="text-xs text-base-content/50 flex gap-4">
        <span>Started {absolute_time(@summary.started_at)}</span>
        <span>Last activity {relative_time(@summary.last_activity_at)}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <div class="text-xs uppercase tracking-wide text-base-content/40">{@label}</div>
      <div class="text-base font-semibold tabular-nums">{@value}</div>
    </div>
    """
  end

  attr :turn, :map, required: true

  defp turn_card(assigns) do
    ~H"""
    <article class="space-y-3">
      <header class="flex items-baseline gap-3">
        <span class="text-xs font-mono text-base-content/40">#{@turn.index}</span>
        <span class="text-xs text-base-content/40">{relative_time(@turn.started_at)}</span>
        <span
          :if={@turn.tokens.input + @turn.tokens.output > 0}
          class="text-xs text-base-content/40 ml-auto tabular-nums"
        >
          {number(@turn.tokens.input + @turn.tokens.cache_read)} in · {number(@turn.tokens.output)} out
        </span>
      </header>

      <.user_message turn={@turn} />

      <div :for={block <- @turn.blocks} class="ml-4 pl-4 border-l-2 border-base-200">
        <.block block={block} />
      </div>
    </article>
    """
  end

  attr :turn, :map, required: true

  defp user_message(%{turn: %{user_kind: :slash_command}} = assigns) do
    ~H"""
    <div class="rounded-md bg-base-200/60 px-3 py-2 text-sm text-base-content/70 inline-flex items-center gap-2">
      <.icon name="hero-command-line" class="h-3.5 w-3.5" />
      <code class="font-mono">{@turn.user_text}</code>
    </div>
    """
  end

  defp user_message(assigns) do
    ~H"""
    <div class="rounded-lg bg-primary/5 border border-primary/20 px-4 py-3 text-sm whitespace-pre-wrap">
      {@turn.user_text}
    </div>
    """
  end

  attr :block, :map, required: true

  defp block(%{block: %{kind: :text}} = assigns) do
    ~H"""
    <div class="text-sm whitespace-pre-wrap text-base-content/90 py-1">
      {@block.data.text}
    </div>
    """
  end

  defp block(%{block: %{kind: :thinking, data: %{text: text}}} = assigns)
       when text in [nil, ""] do
    ~H"""
    <div class="text-xs text-base-content/40 inline-flex items-center gap-1 py-1">
      <.icon name="hero-light-bulb" class="h-3 w-3" /> thinking · encrypted
    </div>
    """
  end

  defp block(%{block: %{kind: :thinking}} = assigns) do
    ~H"""
    <details class="group py-1">
      <summary class="text-xs text-base-content/40 cursor-pointer hover:text-base-content/60 inline-flex items-center gap-1">
        <.icon name="hero-light-bulb" class="h-3 w-3" /> thinking
      </summary>
      <div class="mt-2 text-xs italic text-base-content/60 whitespace-pre-wrap pl-4">
        {@block.data.text}
      </div>
    </details>
    """
  end

  defp block(%{block: %{kind: :tool_use}} = assigns) do
    assigns =
      assigns
      |> assign(:summary, tool_summary(assigns.block.data))
      |> assign(:input_pretty, pretty_json(assigns.block.data.input))
      |> assign(:result, assigns.block.data[:result])

    ~H"""
    <details class="group py-1">
      <summary class="cursor-pointer hover:bg-base-200/40 rounded px-2 py-1 -mx-2 text-sm flex items-start gap-2">
        <.icon
          name="hero-wrench-screwdriver"
          class="h-3.5 w-3.5 mt-0.5 shrink-0 text-base-content/50"
        />
        <span class="font-mono text-base-content/80 shrink-0">{@block.data.name}</span>
        <span class="text-base-content/50 truncate min-w-0">{@summary}</span>
        <span :if={@result && @result.is_error} class="ml-auto text-xs text-error shrink-0">
          error
        </span>
      </summary>

      <div class="mt-2 ml-5 space-y-2">
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/40 mb-1">Input</div>
          <pre
            phx-no-curly-interpolation
            class="text-xs bg-base-200/60 rounded p-2 overflow-x-auto whitespace-pre-wrap break-words"
          ><code><%= @input_pretty %></code></pre>
        </div>
        <div :if={@result}>
          <div class="text-xs uppercase tracking-wide text-base-content/40 mb-1">
            Result {if @result.is_error, do: "(error)"}
          </div>
          <.tool_result content={@result.content} />
        </div>
        <div :if={!@result} class="text-xs text-base-content/40 italic">No result yet.</div>
      </div>
    </details>
    """
  end

  defp block(%{block: %{kind: :tool_result}} = assigns) do
    # Should be rare — tool_results are normally paired into tool_use blocks.
    ~H"""
    <div class="text-xs text-base-content/40">orphan tool_result for {@block.data.tool_use_id}</div>
    """
  end

  defp block(%{block: %{kind: :unknown}} = assigns) do
    ~H"""
    <div class="text-xs text-base-content/40 font-mono">
      unknown block: {inspect(@block.data, pretty: true, limit: 5)}
    </div>
    """
  end

  attr :content, :any, required: true

  defp tool_result(%{content: content} = assigns) when is_binary(content) do
    ~H"""
    <pre
      phx-no-curly-interpolation
      class="text-xs bg-base-200/60 rounded p-2 overflow-x-auto whitespace-pre-wrap break-words max-h-96"
    ><code><%= @content %></code></pre>
    """
  end

  defp tool_result(%{content: content} = assigns) when is_list(content) do
    parts =
      Enum.map(content, fn
        %{"type" => "text", "text" => text} when is_binary(text) -> {:text, text}
        other -> {:raw, inspect(other, pretty: true)}
      end)

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <div class="space-y-2">
      <pre
        :for={{_kind, body} <- @parts}
        phx-no-curly-interpolation
        class="text-xs bg-base-200/60 rounded p-2 overflow-x-auto whitespace-pre-wrap break-words max-h-96"
      ><code><%= body %></code></pre>
    </div>
    """
  end

  defp tool_result(assigns) do
    ~H"""
    <div class="text-xs text-base-content/40">no result content</div>
    """
  end

  defp tool_summary(%{name: "Bash", input: %{"command" => cmd}}), do: truncate(cmd, 80)

  defp tool_summary(%{name: name, input: %{"file_path" => p}})
       when name in ["Read", "Edit", "Write"],
       do: truncate(p, 100)

  defp tool_summary(%{name: "Grep", input: %{"pattern" => p}}), do: ~s("#{truncate(p, 60)}")
  defp tool_summary(%{name: "Glob", input: %{"pattern" => p}}), do: truncate(p, 80)

  defp tool_summary(%{name: name, input: %{"description" => d}}) when name in ["Agent", "Task"],
    do: truncate(d, 80)

  defp tool_summary(%{name: "TaskCreate", input: %{"subject" => s}}), do: truncate(s, 80)

  defp tool_summary(%{name: "TaskUpdate", input: %{"taskId" => id, "status" => s}}),
    do: "##{id} → #{s}"

  defp tool_summary(%{name: "WebFetch", input: %{"url" => u}}), do: truncate(u, 80)
  defp tool_summary(%{name: "WebSearch", input: %{"query" => q}}), do: ~s("#{truncate(q, 60)}")

  defp tool_summary(%{input: input}) when is_map(input) do
    input
    |> Enum.find_value(fn
      {_k, v} when is_binary(v) -> v
      _ -> nil
    end)
    |> case do
      nil -> ""
      v -> truncate(v, 80)
    end
  end

  defp tool_summary(_), do: ""

  defp truncate(s, n) when is_binary(s) do
    s = String.replace(s, ~r/\s+/, " ")
    if String.length(s) <= n, do: s, else: String.slice(s, 0, n) <> "…"
  end

  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true)
    end
  end
end
