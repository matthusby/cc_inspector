defmodule CcInspector.Sessions.UsageTest do
  use ExUnit.Case, async: true

  alias CcInspector.Sessions.Usage

  defp tokens(opts) do
    %{
      input: Keyword.get(opts, :input, 0),
      output: Keyword.get(opts, :output, 0),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_creation: Keyword.get(opts, :cache_creation, 0),
      reasoning: Keyword.get(opts, :reasoning, 0)
    }
  end

  defp at(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  describe "add/3" do
    test "buckets by the hour the timestamp falls in" do
      buckets =
        Usage.new()
        |> Usage.add(at("2026-08-08T10:05:00Z"), tokens(input: 10))
        |> Usage.add(at("2026-08-08T10:55:00Z"), tokens(input: 5))
        |> Usage.add(at("2026-08-08T11:01:00Z"), tokens(input: 1))

      assert map_size(buckets) == 2
      assert buckets[Usage.hour_key(at("2026-08-08T10:30:00Z"))].input == 15
      assert buckets[Usage.hour_key(at("2026-08-08T11:59:00Z"))].input == 1
    end

    test "tolerates usage maps missing keys" do
      # Claude reports no :reasoning, Codex reports no :cache_creation.
      buckets = Usage.add(Usage.new(), at("2026-08-08T10:00:00Z"), %{input: 3, output: 4})

      assert [{_hour, totals}] = Map.to_list(buckets)
      assert totals == tokens(input: 3, output: 4)
    end

    test "ignores entries with no timestamp" do
      assert Usage.add(Usage.new(), nil, tokens(input: 10)) == %{}
    end
  end

  describe "merge/1" do
    test "sums overlapping hours across sessions" do
      hour = Usage.hour_key(at("2026-08-08T10:00:00Z"))
      a = Usage.add(Usage.new(), hour, tokens(input: 1, output: 2))
      b = Usage.add(Usage.new(), hour, tokens(input: 10, reasoning: 5))

      assert Usage.merge([a, b]) == %{hour => tokens(input: 11, output: 2, reasoning: 5)}
    end

    test "merging nothing yields nothing" do
      assert Usage.merge([]) == %{}
    end
  end

  describe "daily_series/2" do
    test "rolls UTC hours up into local days using the given offset" do
      # 23:30 UTC is the previous evening at UTC-5, so it belongs to Aug 7.
      buckets =
        Usage.new()
        |> Usage.add(at("2026-08-08T03:30:00Z"), tokens(input: 100))
        |> Usage.add(at("2026-08-08T12:00:00Z"), tokens(input: 7))

      series =
        Usage.daily_series(buckets,
          days: 3,
          offset_seconds: -5 * 3600,
          today: ~D[2026-08-08]
        )

      assert [aug_6, aug_7, aug_8] = series
      assert aug_6.date == ~D[2026-08-06]
      assert aug_6.tokens.input == 0
      assert aug_7.date == ~D[2026-08-07]
      assert aug_7.tokens.input == 100
      assert aug_8.date == ~D[2026-08-08]
      assert aug_8.tokens.input == 7
    end

    test "the same bucket lands on a different day under a different offset" do
      buckets = Usage.add(Usage.new(), at("2026-08-08T03:30:00Z"), tokens(input: 100))
      opts = [days: 3, today: ~D[2026-08-08]]

      utc = Usage.daily_series(buckets, [offset_seconds: 0] ++ opts)
      west = Usage.daily_series(buckets, [offset_seconds: -5 * 3600] ++ opts)

      assert Enum.find(utc, &(&1.date == ~D[2026-08-08])).tokens.input == 100
      assert Enum.find(west, &(&1.date == ~D[2026-08-07])).tokens.input == 100
    end

    test "returns a dense window so idle days keep their slot" do
      series = Usage.daily_series(%{}, days: 30, offset_seconds: 0, today: ~D[2026-08-08])

      assert length(series) == 30
      assert List.first(series).date == ~D[2026-07-10]
      assert List.last(series).date == ~D[2026-08-08]
      assert Enum.all?(series, &(Usage.total(&1.tokens) == 0))
    end

    test "drops buckets outside the window" do
      buckets = Usage.add(Usage.new(), at("2026-01-01T00:00:00Z"), tokens(input: 999))
      series = Usage.daily_series(buckets, days: 30, offset_seconds: 0, today: ~D[2026-08-08])

      assert Enum.all?(series, &(Usage.total(&1.tokens) == 0))
    end
  end

  describe "window_totals/1" do
    test "splits the window into the trailing 7 days and the 7 before" do
      series =
        Enum.map(0..29, fn index ->
          %{date: Date.add(~D[2026-07-10], index), tokens: tokens(input: 1)}
        end)

      totals = Usage.window_totals(series)

      assert totals.window.input == 30
      assert totals.last_7.input == 7
      assert totals.prior_7.input == 7
    end

    test "handles a window shorter than 14 days without crashing" do
      series = Enum.map(0..3, &%{date: Date.add(~D[2026-08-05], &1), tokens: tokens(input: 2)})
      totals = Usage.window_totals(series)

      assert totals.window.input == 8
      assert totals.last_7.input == 8
      assert totals.prior_7.input == 0
    end
  end

  describe "percent_change/2" do
    test "is nil against a zero baseline rather than infinite" do
      assert Usage.percent_change(100, 0) == nil
    end

    test "reports signed change" do
      assert Usage.percent_change(150, 100) == 50.0
      assert Usage.percent_change(50, 100) == -50.0
    end
  end

  describe "local_offset_seconds/0" do
    test "returns a whole number of minutes within a day" do
      offset = Usage.local_offset_seconds()

      assert is_integer(offset)
      assert offset > -86_400 and offset < 86_400
      assert rem(offset, 60) == 0
    end
  end
end
