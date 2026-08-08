defmodule CcInspector.Sessions.DashboardTest do
  use ExUnit.Case, async: true

  alias CcInspector.Sessions.{Dashboard, Summary, Usage}

  @today ~D[2026-08-08]
  @opts [days: 30, offset_seconds: 0, today: @today]

  defp summary(provider, buckets) do
    %Summary{
      provider: provider,
      session_id: "s#{System.unique_integer([:positive])}",
      usage: buckets
    }
  end

  defp buckets(entries) do
    Enum.reduce(entries, Usage.new(), fn {iso, tokens}, acc ->
      {:ok, dt, _} = DateTime.from_iso8601(iso)
      Usage.add(acc, dt, tokens)
    end)
  end

  defp on(date, series), do: Enum.find(series, &(&1.date == date)).tokens

  test "merges sessions of the same provider into one series" do
    summaries = [
      summary(:claude, buckets([{"2026-08-08T10:00:00Z", %{input: 10}}])),
      summary(:claude, buckets([{"2026-08-08T14:00:00Z", %{input: 5}}]))
    ]

    dash = Dashboard.build(summaries, @opts)

    assert [%{provider: :claude, series: series}] = dash.by_provider
    assert on(@today, series).input == 15
    assert on(@today, dash.series).input == 15
  end

  test "keeps providers separate and sums them into the combined series" do
    summaries = [
      summary(:claude, buckets([{"2026-08-08T10:00:00Z", %{input: 10}}])),
      summary(:codex, buckets([{"2026-08-08T10:00:00Z", %{input: 3, reasoning: 7}}])),
      summary(:opencode, buckets([{"2026-08-08T10:00:00Z", %{output: 1}}]))
    ]

    dash = Dashboard.build(summaries, @opts)

    assert Enum.map(dash.by_provider, & &1.provider) == [:claude, :codex, :opencode]

    assert on(@today, dash.series) == %{
             input: 13,
             output: 1,
             cache_read: 0,
             cache_creation: 0,
             reasoning: 7
           }
  end

  test "every provider series covers the same dense window, so they zip up" do
    summaries = [
      summary(:claude, buckets([{"2026-07-20T10:00:00Z", %{input: 1}}])),
      summary(:codex, buckets([{"2026-08-08T10:00:00Z", %{input: 1}}]))
    ]

    dash = Dashboard.build(summaries, @opts)

    assert length(dash.series) == 30
    assert Enum.all?(dash.by_provider, &(length(&1.series) == 30))
    assert Enum.map(dash.series, & &1.date) == Enum.map(hd(dash.by_provider).series, & &1.date)
  end

  test "totals split the window into 30d, trailing 7d, and the prior 7d" do
    summaries = [
      summary(
        :claude,
        buckets([
          # inside the trailing 7 days
          {"2026-08-06T10:00:00Z", %{input: 100}},
          # inside the prior 7 days
          {"2026-07-30T10:00:00Z", %{input: 40}},
          # inside the window but older than 14 days
          {"2026-07-15T10:00:00Z", %{input: 7}}
        ])
      )
    ]

    totals = Dashboard.build(summaries, @opts).totals

    assert totals.window.input == 147
    assert totals.last_7.input == 100
    assert totals.prior_7.input == 40
  end

  test "an empty dashboard still has a full zeroed window" do
    dash = Dashboard.empty(@opts)

    assert dash.by_provider == []
    assert length(dash.series) == 30
    assert Usage.total(dash.totals.window) == 0
  end

  test "survives a summary cached before usage buckets existed" do
    stale = Map.delete(summary(:claude, %{}), :usage)

    assert Usage.total(Dashboard.build([stale], @opts).totals.window) == 0
  end

  test "only Claude is known not to report reasoning tokens" do
    refute Dashboard.reports_reasoning?(:claude)
    assert Dashboard.reports_reasoning?(:codex)
    assert Dashboard.reports_reasoning?(:opencode)
  end
end
