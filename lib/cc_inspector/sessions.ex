defmodule CcInspector.Sessions do
  @moduledoc """
  Read-only view of local Claude Code, Codex, and OpenCode sessions.
  """

  alias CcInspector.Sessions.{Claude, Codex, OpenCode}

  # Sessions whose JSONL has no timestamped entries have a nil
  # last_activity_at, which DateTime.compare/2 can't sort. Treat them as the
  # epoch so they sort to the bottom instead of crashing.
  @epoch ~U[1970-01-01 00:00:00Z]

  def list_summaries, do: load().summaries

  @doc """
  Loads every enabled provider, reporting which ones failed rather than folding
  a failure into an empty list — one provider being unreadable should show up in
  the UI, not silently shrink the numbers.
  """
  def load do
    results =
      enabled_providers()
      |> Task.async_stream(&{&1, load_provider(&1)}, timeout: :infinity)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {nil, {:error, :exited}}
      end)

    summaries =
      results
      |> Enum.flat_map(fn
        {_provider, {:ok, summaries}} -> summaries
        _ -> []
      end)
      |> Enum.uniq_by(&{&1.provider, &1.session_id})
      |> Enum.sort_by(&(&1.last_activity_at || @epoch), {:desc, DateTime})

    failed = for {provider, {:error, _}} <- results, not is_nil(provider), do: provider

    %{summaries: summaries, failed_providers: failed}
  end

  defp load_provider(:opencode), do: OpenCode.list_summaries_result()

  defp load_provider(provider) do
    {:ok, list_provider_summaries(provider)}
  rescue
    error -> {:error, error}
  end

  def get_summary(provider, session_id) do
    with {:ok, provider} <- parse_provider(provider),
         true <- provider in enabled_providers() do
      provider_module(provider).get_summary(session_id)
    else
      _ -> nil
    end
  end

  def get_turns(provider, session_id) do
    with {:ok, provider} <- parse_provider(provider),
         true <- provider in enabled_providers() do
      provider_module(provider).get_turns(session_id)
    else
      _ -> nil
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(CcInspector.PubSub, "sessions")

  def subscribe(provider, session_id) when is_binary(session_id) do
    with {:ok, provider} <- parse_provider(provider) do
      Phoenix.PubSub.subscribe(CcInspector.PubSub, "session:#{provider}:#{session_id}")
      Phoenix.PubSub.subscribe(CcInspector.PubSub, "provider:#{provider}")
    end
  end

  def enabled_providers do
    Application.get_env(:cc_inspector, :session_providers, [:claude, :codex, :opencode])
  end

  def provider_label(:claude), do: "Claude Code"
  def provider_label(:codex), do: "Codex"
  def provider_label(:opencode), do: "OpenCode"

  def provider_label(provider) do
    case parse_provider(provider) do
      {:ok, parsed} -> provider_label(parsed)
      _ -> "Unknown"
    end
  end

  def provider_slug(provider) when is_atom(provider), do: Atom.to_string(provider)

  def parse_provider(provider) when provider in [:claude, :codex, :opencode], do: {:ok, provider}
  def parse_provider("claude"), do: {:ok, :claude}
  def parse_provider("codex"), do: {:ok, :codex}
  def parse_provider("opencode"), do: {:ok, :opencode}
  def parse_provider(_), do: :error

  defp list_provider_summaries(provider), do: provider_module(provider).list_summaries()
  defp provider_module(:claude), do: Claude
  defp provider_module(:codex), do: Codex
  defp provider_module(:opencode), do: OpenCode
end
