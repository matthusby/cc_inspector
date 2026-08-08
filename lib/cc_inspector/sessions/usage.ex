defmodule CcInspector.Sessions.Usage do
  @moduledoc """
  Per-hour token buckets, and the rollup from those buckets into daily series.

  Buckets are `%{unix_hour => tokens}` where `unix_hour` is
  `div(unix_seconds, 3600)` — a plain integer, so a bucket map stays cheap to
  hold in ETS for every cached session.

  Hours rather than days on purpose. Buckets are built once at parse time and
  cached, but "which day was this token spent on" depends on the viewer's
  timezone, and a laptop that moves timezones would otherwise invalidate every
  cached parse. Storing UTC hours and shifting at rollup keeps the cache stable
  and the day boundaries local. Bars spanning a past DST transition are off by
  an hour at the edge, which is not worth a timezone database to fix.
  """

  @empty %{input: 0, output: 0, cache_read: 0, cache_creation: 0, reasoning: 0}
  @hour_seconds 3600
  @default_days 30

  @doc "A zeroed token map, with every key the dashboard expects."
  def empty_tokens, do: @empty

  @doc "An empty bucket map."
  def new, do: %{}

  @doc "The unix-hour key a timestamp falls into."
  def hour_key(%DateTime{} = ts), do: ts |> DateTime.to_unix() |> Integer.floor_div(@hour_seconds)

  @doc """
  Adds a usage map into the bucket for `ts`.

  Tolerates nil timestamps and usage maps missing keys (Claude never reports
  `:reasoning`, Codex never reports `:cache_creation`), so callers can fold raw
  provider payloads straight in.
  """
  def add(buckets, nil, _tokens), do: buckets
  def add(buckets, _ts, nil), do: buckets

  def add(buckets, %DateTime{} = ts, tokens), do: add(buckets, hour_key(ts), tokens)

  def add(buckets, hour, tokens) when is_integer(hour) and is_map(tokens) do
    Map.update(buckets, hour, normalize(tokens), &sum(&1, tokens))
  end

  @doc "Merges many bucket maps into one."
  def merge(buckets_list) when is_list(buckets_list) do
    Enum.reduce(buckets_list, %{}, fn buckets, acc ->
      Map.merge(acc, buckets, fn _hour, left, right -> sum(left, right) end)
    end)
  end

  @doc "Adds two token maps. The right side may omit keys."
  def sum(a, b) do
    %{
      input: a.input + Map.get(b, :input, 0),
      output: a.output + Map.get(b, :output, 0),
      cache_read: a.cache_read + Map.get(b, :cache_read, 0),
      cache_creation: a.cache_creation + Map.get(b, :cache_creation, 0),
      reasoning: a.reasoning + Map.get(b, :reasoning, 0)
    }
  end

  @doc "Adds up a list of token maps."
  def sum_all(token_maps), do: Enum.reduce(token_maps, @empty, &sum(&2, &1))

  @doc "Every token key totalled into one number."
  def total(tokens) do
    tokens.input + tokens.output + tokens.cache_read + tokens.cache_creation + tokens.reasoning
  end

  @doc """
  The machine's current UTC offset in seconds.

  Derived from the runtime rather than a timezone database, which Elixir has no
  default for. Reflects the offset in effect right now, not at each historical
  timestamp.
  """
  def local_offset_seconds do
    local = NaiveDateTime.from_erl!(:calendar.local_time())
    utc = NaiveDateTime.from_erl!(:calendar.universal_time())
    NaiveDateTime.diff(local, utc)
  end

  @doc """
  Rolls buckets up into a dense, chronologically ordered list of
  `%{date: Date.t(), tokens: map}` covering the last `:days` local days.

  Dense on purpose: idle days come back as zeroed entries so the chart can draw
  a continuous axis instead of silently compressing a gap.
  """
  def daily_series(buckets, opts \\ []) do
    days = Keyword.get(opts, :days, @default_days)
    offset = Keyword.get(opts, :offset_seconds, local_offset_seconds())
    last_day = Keyword.get(opts, :today, today(offset))
    first_day = Date.add(last_day, -(days - 1))

    totals =
      Enum.reduce(buckets, %{}, fn {hour, tokens}, acc ->
        date = hour_to_date(hour, offset)

        if Date.before?(date, first_day) or Date.after?(date, last_day) do
          acc
        else
          Map.update(acc, date, tokens, &sum(&1, tokens))
        end
      end)

    Enum.map(0..(days - 1), fn index ->
      date = Date.add(first_day, index)
      %{date: date, tokens: Map.get(totals, date, @empty)}
    end)
  end

  @doc "A zeroed series of `days` entries, for the loading state."
  def empty_series(opts \\ []), do: daily_series(%{}, opts)

  @doc """
  Window totals derived from a daily series: the whole window, the trailing 7
  days, and the 7 days before those (for the trend delta).

  Reads from the end of the series so it stays correct for any window length of
  at least 14 days.
  """
  def window_totals(series) do
    count = length(series)

    %{
      window: total_of(series),
      last_7: series |> Enum.slice(max(count - 7, 0), 7) |> total_of(),
      prior_7: series |> Enum.slice(max(count - 14, 0), min(max(count - 7, 0), 7)) |> total_of()
    }
  end

  defp total_of(series), do: series |> Enum.map(& &1.tokens) |> sum_all()

  @doc """
  Percentage change between two totals, or nil when there is no honest
  comparison to draw (a zero baseline makes the percentage meaningless).
  """
  def percent_change(_current, 0), do: nil
  def percent_change(current, previous), do: (current - previous) / previous * 100

  defp today(offset) do
    DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.to_date()
  end

  defp hour_to_date(hour, offset) do
    (hour * @hour_seconds + offset) |> DateTime.from_unix!() |> DateTime.to_date()
  end

  defp normalize(tokens), do: sum(@empty, tokens)
end
