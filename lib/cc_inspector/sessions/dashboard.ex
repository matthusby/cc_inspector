defmodule CcInspector.Sessions.Dashboard do
  @moduledoc """
  Assembles the index page's usage dashboard from session summaries.

  Every summary already carries its own hourly buckets, so this is a merge and a
  rollup rather than a scan — the whole thing runs in single-digit milliseconds
  over a couple of thousand sessions. Keeping it out of the LiveView means the
  numbers can be tested without rendering anything.
  """

  alias CcInspector.Sessions.Usage

  @days 30

  @doc """
  Builds the view model for `summaries`, which are expected to be pre-filtered by
  the provider pill (and only by the pill — the text filter deliberately doesn't
  reach the dashboard).

  Options: `:days`, `:offset_seconds`, `:today` — all mainly for tests.
  """
  def build(summaries, opts \\ []) do
    days = Keyword.get(opts, :days, @days)

    series_opts =
      [
        days: days,
        offset_seconds: Keyword.get(opts, :offset_seconds, Usage.local_offset_seconds())
      ] ++
        Keyword.take(opts, [:today])

    by_provider =
      summaries
      |> Enum.group_by(& &1.provider)
      |> Enum.map(fn {provider, group} ->
        # Map.get rather than dot access: a summary from an older cache entry
        # has no :usage key, and an empty chart beats crashing the index page.
        buckets = group |> Enum.map(&(Map.get(&1, :usage) || %{})) |> Usage.merge()
        %{provider: provider, series: Usage.daily_series(buckets, series_opts)}
      end)
      |> Enum.sort_by(&provider_order(&1.provider))

    series = combine(by_provider, series_opts)

    %{
      days: days,
      series: series,
      by_provider: by_provider,
      totals: Usage.window_totals(series)
    }
  end

  @doc "An all-zero dashboard, for the loading state."
  def empty(opts \\ []), do: build([], opts)

  # Claude reports no reasoning tokens at all, so a Claude-only view would show
  # an empty Reasoning series with no explanation. The dashboard greys the legend
  # entry instead of letting it silently vanish.
  def reports_reasoning?(:claude), do: false
  def reports_reasoning?(_), do: true

  defp combine([], opts), do: Usage.empty_series(opts)

  defp combine(by_provider, _opts) do
    by_provider
    |> Enum.map(& &1.series)
    |> Enum.zip_with(fn entries ->
      %{
        date: hd(entries).date,
        tokens: entries |> Enum.map(& &1.tokens) |> Usage.sum_all()
      }
    end)
  end

  defp provider_order(:claude), do: 0
  defp provider_order(:codex), do: 1
  defp provider_order(:opencode), do: 2
  defp provider_order(_), do: 3
end
