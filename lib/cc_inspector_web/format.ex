defmodule CcInspectorWeb.Format do
  @moduledoc """
  Formatting helpers for displaying session data.
  """

  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
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

  def project_name(cwd) when is_binary(cwd), do: Path.basename(cwd)
  def project_name(_), do: "—"
end
