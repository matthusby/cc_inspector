defmodule CcInspectorWeb.Format do
  @moduledoc """
  Formatting helpers for displaying session data.
  """

  @seven_days_seconds 7 * 86_400

  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < @seven_days_seconds -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(ts, "%Y-%m-%d")
    end
  end

  def absolute_time(nil), do: "—"

  def absolute_time(%DateTime{} = ts) do
    Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S UTC")
  end

  def duration(nil), do: "—"
  def duration(ms) when ms < 1000, do: "#{ms}ms"

  def duration(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  def number(nil), do: "0"
  def number(0), do: "0"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Compact number for display where the exact digits don't matter, e.g.
  `853_722_909` becomes `"853.7M"`. Pair it with `number/1` in a title attribute
  when the precise value should stay one hover away.
  """
  def abbrev_number(nil), do: "0"
  def abbrev_number(n) when is_integer(n) and n < 0, do: "-" <> abbrev_number(-n)
  def abbrev_number(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)
  def abbrev_number(n) when n < 1_000_000, do: scaled(n, 1_000, "K")
  def abbrev_number(n) when n < 1_000_000_000, do: scaled(n, 1_000_000, "M")
  def abbrev_number(n) when n < 1_000_000_000_000, do: scaled(n, 1_000_000_000, "B")
  def abbrev_number(n), do: scaled(n, 1_000_000_000_000, "T")

  @doc "Signed percentage for trend deltas, e.g. `\"+12.4%\"`. Nil renders as an em dash."
  def percent_delta(nil), do: "—"

  def percent_delta(value) when is_number(value) do
    sign = if value < 0, do: "−", else: "+"
    sign <> :erlang.float_to_binary(abs(value) / 1, decimals: 1) <> "%"
  end

  def project_name(cwd) when is_binary(cwd), do: Path.basename(cwd)
  def project_name(_), do: "—"

  defp scaled(n, unit, suffix) do
    (n / unit)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
    |> Kernel.<>(suffix)
  end
end
