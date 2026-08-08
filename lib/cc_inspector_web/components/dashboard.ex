defmodule CcInspectorWeb.Dashboard do
  @moduledoc """
  The usage band above the session list: four stat cards with sparklines, and
  two stacked-bar charts sharing one y-axis.

  Charts are plain SVG built here rather than by a JS charting library — the app
  has no npm build, and server-rendered SVG updates through normal LiveView
  diffs and picks up the theme from CSS variables for free.
  """
  use CcInspectorWeb, :html

  alias CcInspector.Sessions
  alias CcInspector.Sessions.Usage

  # Chart geometry, in viewBox units. An SVG viewBox scales uniformly, so the
  # viewBox width has to track the rendered width or the axis text scales with
  # it — a full-width chart drawn at the half-width viewBox renders its labels
  # nearly twice the size of everything around them.
  @vb_w 680
  @vb_w_wide 1380
  @vb_h 200
  @pad_l 48
  @pad_r 12
  @pad_t 12
  @pad_b 26
  # The surface gap that separates stacked segments, and the rounded data-end.
  @seg_gap 2
  @radius 4
  @max_bar 24

  @token_series [
    %{key: :input, label: "Input", color: "var(--viz-1)"},
    %{key: :cached, label: "Cached", color: "var(--viz-2)"},
    %{key: :output, label: "Output", color: "var(--viz-3)"},
    %{key: :reasoning, label: "Reasoning", color: "var(--viz-4)"}
  ]

  # The cards are not the chart's series list: Reasoning is too small a share to
  # sit as a peer card (and Claude never reports it at all), so it lives in the
  # chart stack, and the fourth card is the Total the stack adds up to.
  @card_series [
    %{key: :input, label: "Input", color: "var(--viz-1)"},
    %{key: :cached, label: "Cached", color: "var(--viz-2)"},
    %{key: :output, label: "Output", color: "var(--viz-3)"},
    %{key: :total, label: "Total", color: "var(--viz-neutral)"}
  ]

  @provider_colors %{claude: "var(--viz-5)", codex: "var(--viz-6)", opencode: "var(--viz-7)"}

  def token_series, do: @token_series
  def token_keys, do: Enum.map(@token_series, & &1.key)

  @doc """
  Reads one displayed metric out of a raw token map.

  `:cached` folds cache reads and cache writes together so the four chart
  segments add up to the Total card exactly; the split stays in the tooltip.
  """
  def metric(tokens, :cached), do: tokens.cache_read + tokens.cache_creation
  def metric(tokens, :total), do: Usage.total(tokens)
  def metric(tokens, key), do: Map.get(tokens, key, 0)

  attr :dashboard, :map, required: true
  attr :collapsed, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :failed_providers, :list, default: []
  attr :hidden_types, :list, default: []
  attr :hidden_providers, :list, default: []
  attr :provider_filter, :string, default: "all"

  def usage_dashboard(assigns) do
    enabled_types = Enum.reject(token_keys(), &(&1 in assigns.hidden_types))

    visible_providers =
      assigns.dashboard.by_provider
      |> Enum.map(& &1.provider)
      |> Enum.reject(&(&1 in assigns.hidden_providers))

    type_cols = type_columns(assigns.dashboard.series, enabled_types)
    max = type_cols |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end) |> nice_max()

    # A single pinned provider makes the provider chart a one-color block, so it
    # stands down and lets the type chart use the full width.
    show_provider_chart? = assigns.provider_filter == "all"
    type_width = if show_provider_chart?, do: @vb_w, else: @vb_w_wide

    assigns =
      assigns
      |> assign(:enabled_types, enabled_types)
      |> assign(:card_series, @card_series)
      |> assign(:token_series, @token_series)
      |> assign(:type_columns, lay_out(type_cols, max, type_width))
      |> assign(:type_width, type_width)
      |> assign(
        :provider_columns,
        assigns.dashboard.by_provider
        |> provider_columns(enabled_types, visible_providers)
        |> lay_out(max, @vb_w)
      )
      |> assign(:max, max)
      |> assign(:ticks, ticks(max))
      |> assign(:show_provider_chart?, show_provider_chart?)
      |> assign(
        :reasoning_supported?,
        Enum.any?(
          assigns.dashboard.by_provider,
          &Sessions.Dashboard.reports_reasoning?(&1.provider)
        )
      )

    ~H"""
    <section class="viz rounded-lg border border-base-300 bg-base-100" id="usage-dashboard">
      <div class="flex items-center justify-between gap-4 px-4 pt-3">
        <button
          id="usage-dashboard-toggle"
          type="button"
          phx-click="toggle_dashboard"
          phx-hook=".CollapseMemory"
          class="group flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-base-content/50 hover:text-base-content transition-colors"
          aria-expanded={to_string(not @collapsed)}
          aria-controls="usage-dashboard-body"
        >
          <span class={["collapsible-chevron", not @collapsed && "open"]}>
            <.icon name="hero-chevron-right" class="size-3.5" />
          </span>
          Last 30 days
        </button>

        <p :if={@failed_providers != []} class="text-xs text-base-content/50">
          <.icon name="hero-exclamation-triangle" class="size-3.5 -mt-0.5" />
          Couldn't read {Enum.map_join(@failed_providers, ", ", &Sessions.provider_label/1)}
        </p>
      </div>

      <div id="usage-dashboard-body" class={["px-4 pb-4 pt-3", @collapsed && "hidden"]}>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <.stat_card
            :for={series <- @card_series}
            id={"stat-#{series.key}"}
            label={series.label}
            metric={series.key}
            color={series.color}
            dashboard={@dashboard}
            loading={@loading}
          />
        </div>

        <div
          id="usage-charts"
          phx-hook=".ChartHover"
          class="relative mt-4 grid grid-cols-1 min-[900px]:grid-cols-2 gap-4"
        >
          <div class={["min-w-0", not @show_provider_chart? && "min-[900px]:col-span-2"]}>
            <.chart_legend
              id="legend-types"
              title="By token type"
              event="toggle_type"
              items={
                Enum.map(@token_series, fn s ->
                  %{
                    value: Atom.to_string(s.key),
                    label: s.label,
                    color: s.color,
                    active: s.key in @enabled_types,
                    disabled: s.key == :reasoning and not @reasoning_supported?,
                    hint:
                      if(s.key == :reasoning and not @reasoning_supported?,
                        do: "Claude Code does not report reasoning tokens"
                      )
                  }
                end)
              }
            />
            <.stacked_chart
              id="chart-types"
              columns={@type_columns}
              ticks={@ticks}
              max={@max}
              width={@type_width}
            />
          </div>

          <div :if={@show_provider_chart?} class="min-w-0">
            <.chart_legend
              id="legend-providers"
              title="By provider"
              event="toggle_provider"
              items={
                Enum.map(@dashboard.by_provider, fn p ->
                  %{
                    value: Atom.to_string(p.provider),
                    label: Sessions.provider_label(p.provider),
                    color: provider_color(p.provider),
                    active: p.provider not in @hidden_providers,
                    disabled: false,
                    hint: nil
                  }
                end)
              }
            />
            <.stacked_chart
              id="chart-providers"
              columns={@provider_columns}
              ticks={@ticks}
              max={@max}
              width={680}
            />
          </div>

          <div
            id="usage-chart-tooltip"
            data-tooltip
            phx-update="ignore"
            class="pointer-events-none absolute z-20 hidden min-w-40 rounded-md border border-base-300 bg-base-100 px-3 py-2 text-xs shadow-lg"
          >
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartHover">
        export default {
          mounted() { this.bind() },
          updated() { this.bind() },
          bind() {
            if (this.bound) { return }
            this.bound = true
            this.el.addEventListener("pointermove", (e) => {
              const slot = e.target.closest(".viz-slot")
              if (slot) { this.show(slot, e) } else { this.hide() }
            })
            this.el.addEventListener("pointerleave", () => this.hide())
          },
          tooltip() { return this.el.querySelector("[data-tooltip]") },
          show(slot, event) {
            const index = slot.dataset.index
            this.el.querySelectorAll(".viz-slot").forEach((el) => {
              if (el.dataset.index === index) {
                el.setAttribute("data-active", "")
              } else {
                el.removeAttribute("data-active")
              }
            })

            const tip = this.tooltip()
            const data = JSON.parse(slot.dataset.tip)
            tip.replaceChildren()

            const heading = document.createElement("div")
            heading.className = "font-medium mb-1"
            heading.textContent = data.date
            tip.appendChild(heading)

            data.rows.forEach(([label, value, color]) => {
              const row = document.createElement("div")
              row.className = "flex items-center justify-between gap-4 leading-5"
              const left = document.createElement("span")
              left.className = "flex items-center gap-1.5 text-base-content/60"
              if (color) {
                const dot = document.createElement("span")
                dot.className = "inline-block size-2 rounded-full shrink-0"
                dot.style.background = color
                left.appendChild(dot)
              }
              const name = document.createElement("span")
              name.textContent = label
              left.appendChild(name)
              const right = document.createElement("span")
              right.className = "tabular-nums"
              right.textContent = value
              row.appendChild(left)
              row.appendChild(right)
              tip.appendChild(row)
            })

            const box = this.el.getBoundingClientRect()
            tip.classList.remove("hidden")
            const width = tip.offsetWidth
            let left = event.clientX - box.left + 14
            if (left + width > box.width) { left = event.clientX - box.left - width - 14 }
            tip.style.left = `${Math.max(0, left)}px`
            tip.style.top = `${event.clientY - box.top + 14}px`
          },
          hide() {
            this.el.querySelectorAll(".viz-slot[data-active]").forEach((el) => el.removeAttribute("data-active"))
            this.tooltip().classList.add("hidden")
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CollapseMemory">
        export default {
          mounted() {
            const stored = window.localStorage.getItem("cc:dashboard-collapsed") === "true"
            if (stored !== (this.el.getAttribute("aria-expanded") === "false")) {
              this.pushEvent("restore_dashboard", {collapsed: stored})
            }
            this.handleEvent("dashboard:collapsed", ({collapsed}) => {
              window.localStorage.setItem("cc:dashboard-collapsed", collapsed ? "true" : "false")
            })
          }
        }
      </script>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :metric, :atom, required: true
  attr :color, :string, required: true
  attr :dashboard, :map, required: true
  attr :loading, :boolean, default: false

  defp stat_card(assigns) do
    totals = assigns.dashboard.totals
    current = metric(totals.last_7, assigns.metric)
    previous = metric(totals.prior_7, assigns.metric)

    assigns =
      assigns
      |> assign(:value, metric(totals.window, assigns.metric))
      |> assign(:last_7, current)
      |> assign(:delta, Usage.percent_change(current, previous))
      |> assign(:points, Enum.map(assigns.dashboard.series, &metric(&1.tokens, assigns.metric)))
      |> assign(
        :hint,
        if(assigns.metric == :cached,
          do:
            "reads: #{number(totals.window.cache_read)} · writes: #{number(totals.window.cache_creation)}"
        )
      )

    ~H"""
    <div
      id={@id}
      class="group relative overflow-hidden rounded-lg border border-base-300 bg-base-100 px-4 py-3 transition-colors hover:border-base-content/20"
      title={@hint || number(@value)}
    >
      <div class="flex items-baseline justify-between gap-2">
        <span class="text-xs uppercase tracking-wide text-base-content/50">{@label}</span>
        <span
          :if={@delta}
          class="text-[11px] tabular-nums text-base-content/45"
          title="last 7 days vs the 7 before"
        >
          {if @delta < 0, do: "▼", else: "▲"} {percent_delta(@delta)}
        </span>
      </div>

      <div :if={@loading} class="mt-1 h-7 w-24 animate-pulse rounded bg-base-content/10"></div>
      <div :if={not @loading} class="mt-1 text-2xl font-semibold text-base-content">
        {abbrev_number(@value)}
      </div>

      <div class="mt-0.5 flex items-end justify-between gap-3">
        <span class="text-xs text-base-content/40 whitespace-nowrap">
          7d {abbrev_number(@last_7)}
        </span>
        <.sparkline points={@points} color={@color} loading={@loading} />
      </div>
    </div>
    """
  end

  attr :points, :list, required: true
  attr :color, :string, required: true
  attr :loading, :boolean, default: false

  defp sparkline(assigns) do
    points = assigns.points
    max = Enum.max(points, fn -> 0 end)
    count = max(length(points), 2)
    step = 100 / (count - 1)

    coords =
      points
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        y = if max > 0, do: 28 - value / max * 26, else: 28
        {Float.round(index * step, 2), Float.round(y * 1.0, 2)}
      end)

    assigns =
      assigns
      |> assign(:line, Enum.map_join(coords, " ", fn {x, y} -> "#{x},#{y}" end))
      |> assign(
        :area,
        case coords do
          [] -> ""
          [{first_x, _} | _] -> area_path(coords, first_x)
        end
      )

    ~H"""
    <svg
      :if={not @loading}
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      class="h-8 w-24 shrink-0 overflow-visible"
      aria-hidden="true"
    >
      <path d={@area} fill={@color} opacity="0.15" />
      <polyline
        points={@line}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    <div :if={@loading} class="h-8 w-24 shrink-0 animate-pulse rounded bg-base-content/10"></div>
    """
  end

  attr :id, :string, required: true
  attr :columns, :list, required: true
  attr :ticks, :list, required: true
  attr :max, :integer, required: true
  attr :width, :integer, required: true

  defp stacked_chart(assigns) do
    assigns =
      assigns
      |> assign(:plot_top, @pad_t)
      |> assign(:plot_h, @vb_h - @pad_t - @pad_b)
      |> assign(:plot_l, @pad_l)
      |> assign(:plot_r, assigns.width - @pad_r)
      |> assign(:baseline, @vb_h - @pad_b)
      |> assign(:vb, "0 0 #{assigns.width} #{@vb_h}")
      |> assign(:label_every, label_indices(length(assigns.columns)))

    ~H"""
    <svg id={@id} viewBox={@vb} class="mt-2 w-full" role="img" aria-label="Daily token usage">
      <line
        :for={tick <- @ticks}
        x1={@plot_l}
        x2={@plot_r}
        y1={tick_y(tick, @max)}
        y2={tick_y(tick, @max)}
        stroke="var(--viz-grid)"
        stroke-width="1"
      />
      <text
        :for={tick <- @ticks}
        x={@plot_l - 8}
        y={tick_y(tick, @max) + 3.5}
        text-anchor="end"
        class="fill-base-content/45 tabular-nums"
        font-size="10"
      >
        {abbrev_number(tick)}
      </text>

      <line
        x1={@plot_l}
        x2={@plot_r}
        y1={@baseline}
        y2={@baseline}
        stroke="var(--viz-axis)"
        stroke-width="1"
      />

      <g :for={column <- @columns}>
        <path :for={segment <- column.segments} d={segment.path} fill={segment.color} />
      </g>

      <text
        :for={{column, index} <- Enum.with_index(@columns)}
        :if={index in @label_every}
        x={column.center}
        y={@baseline + 15}
        text-anchor="middle"
        class="fill-base-content/45 tabular-nums"
        font-size="10"
      >
        {Calendar.strftime(column.date, "%b %-d")}
      </text>

      <rect
        :for={{column, index} <- Enum.with_index(@columns)}
        class="viz-slot"
        data-index={index}
        data-tip={column.tip}
        x={column.slot_x}
        y={@plot_top}
        width={column.slot_w}
        height={@plot_h}
      />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :event, :string, required: true
  attr :items, :list, required: true

  defp chart_legend(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <span class="text-xs font-medium text-base-content/60">{@title}</span>
      <div id={@id} class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <button
          :for={item <- @items}
          id={"#{@id}-#{item.value}"}
          type="button"
          phx-click={not item.disabled && @event}
          phx-value-key={item.value}
          disabled={item.disabled}
          title={item.hint}
          class={[
            "flex items-center gap-1.5 text-[11px] transition-opacity",
            item.disabled && "cursor-help opacity-40",
            not item.disabled && item.active && "text-base-content/70 hover:opacity-70",
            not item.disabled && not item.active && "text-base-content/35 hover:opacity-70"
          ]}
        >
          <span
            class="inline-block size-2 rounded-full shrink-0"
            style={"background: #{if item.active and not item.disabled, do: item.color, else: "currentColor"}"}
          />
          {item.label}
        </button>
      </div>
    </div>
    """
  end

  ## ----------------------------------------------------------------
  ## Column building
  ## ----------------------------------------------------------------

  defp type_columns(series, enabled_types) do
    Enum.map(series, fn %{date: date, tokens: tokens} ->
      parts =
        for s <- @token_series, s.key in enabled_types do
          %{label: s.label, color: s.color, value: metric(tokens, s.key)}
        end

      %{date: date, parts: parts, total: Enum.reduce(parts, 0, &(&1.value + &2))}
    end)
  end

  defp provider_columns(by_provider, enabled_types, visible_providers) do
    visible = Enum.filter(by_provider, &(&1.provider in visible_providers))

    case visible do
      [] ->
        []

      _ ->
        visible
        |> Enum.map(& &1.series)
        |> Enum.zip_with(fn entries ->
          parts =
            visible
            |> Enum.zip(entries)
            |> Enum.map(fn {provider, entry} ->
              %{
                label: Sessions.provider_label(provider.provider),
                color: provider_color(provider.provider),
                value: enabled_total(entry.tokens, enabled_types)
              }
            end)

          %{
            date: hd(entries).date,
            parts: parts,
            total: Enum.reduce(parts, 0, &(&1.value + &2))
          }
        end)
    end
  end

  defp enabled_total(tokens, enabled_types),
    do: Enum.reduce(enabled_types, 0, &(metric(tokens, &1) + &2))

  ## ----------------------------------------------------------------
  ## Geometry
  ## ----------------------------------------------------------------

  defp lay_out([], _max, _vb_w), do: []

  defp lay_out(columns, max, vb_w) do
    count = length(columns)
    plot_w = vb_w - @pad_l - @pad_r
    plot_h = @vb_h - @pad_t - @pad_b
    slot_w = plot_w / count
    bar_w = min(@max_bar * 1.0, slot_w - 6)
    baseline = @vb_h - @pad_b

    columns
    |> Enum.with_index()
    |> Enum.map(fn {column, index} ->
      slot_x = @pad_l + slot_w * index
      x = slot_x + (slot_w - bar_w) / 2

      %{
        date: column.date,
        slot_x: round2(slot_x),
        slot_w: round2(slot_w),
        center: round2(slot_x + slot_w / 2),
        segments: segments(column.parts, x, bar_w, baseline, plot_h, max),
        tip: tip(column)
      }
    end)
  end

  defp segments(parts, x, bar_w, baseline, plot_h, max) do
    {drawn, _bottom, _any?} =
      Enum.reduce(parts, {[], baseline, false}, fn part, {acc, bottom, any?} ->
        height = if max > 0, do: part.value / max * plot_h, else: 0.0
        top = bottom - height
        # The gap is carved out of the segment itself, so touching segments are
        # separated by surface rather than by a stroke. The lowest drawn segment
        # keeps its full height so the bar sits flush on the baseline.
        visible = if any?, do: height - @seg_gap, else: height

        if part.value > 0 and visible >= 0.75 do
          {[%{y: top, h: visible, color: part.color} | acc], top, true}
        else
          {acc, top, any?}
        end
      end)

    # `drawn` is topmost-first because the reduce prepends; only the top of the
    # whole bar gets the rounded data-end.
    drawn
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      %{
        color: segment.color,
        path: bar_path(x, segment.y, bar_w, segment.h, index == 0)
      }
    end)
  end

  defp bar_path(x, y, w, h, round_top?) do
    r = if round_top?, do: min(@radius * 1.0, min(h, w / 2)), else: 0.0

    if r > 0 do
      "M#{round2(x)} #{round2(y + h)}V#{round2(y + r)}A#{round2(r)} #{round2(r)} 0 0 1 #{round2(x + r)} #{round2(y)}H#{round2(x + w - r)}A#{round2(r)} #{round2(r)} 0 0 1 #{round2(x + w)} #{round2(y + r)}V#{round2(y + h)}Z"
    else
      "M#{round2(x)} #{round2(y)}h#{round2(w)}v#{round2(h)}h-#{round2(w)}Z"
    end
  end

  defp tip(column) do
    rows =
      column.parts
      |> Enum.map(fn part -> [part.label, number(part.value), part.color] end)
      |> Kernel.++([["Total", number(column.total), nil]])

    Jason.encode!(%{date: Calendar.strftime(column.date, "%a %b %-d"), rows: rows})
  end

  defp tick_y(tick, max) do
    plot_h = @vb_h - @pad_t - @pad_b
    ratio = if max > 0, do: tick / max, else: 0
    round2(@pad_t + plot_h - ratio * plot_h)
  end

  defp ticks(max) when max <= 0, do: [0]
  defp ticks(max), do: [0, div(max, 2), max]

  # Round the axis up to a 1/2/5 × 10ⁿ so the tick labels are readable numbers
  # rather than whatever the busiest day happened to be.
  defp nice_max(max) when max <= 0, do: 0

  defp nice_max(max) do
    exponent = max |> :math.log10() |> Float.floor() |> trunc()
    base = :math.pow(10, exponent)
    ratio = max / base

    multiplier = Enum.find([1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10], 10, &(ratio <= &1))

    trunc(Float.ceil(multiplier * base))
  end

  defp label_indices(count) when count <= 0, do: []

  defp label_indices(count) do
    last = count - 1
    for index <- 0..last, rem(last - index, 5) == 0, do: index
  end

  defp area_path(coords, first_x) do
    {last_x, _} = List.last(coords)
    line = Enum.map_join(coords, " ", fn {x, y} -> "L#{x} #{y}" end)
    "M#{first_x} 30 #{line} L#{last_x} 30 Z"
  end

  defp provider_color(provider), do: Map.get(@provider_colors, provider, "var(--viz-5)")

  defp round2(value) when is_float(value), do: Float.round(value, 2)
  defp round2(value), do: value
end
