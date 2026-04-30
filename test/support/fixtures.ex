defmodule CcInspector.SessionFixtures do
  @moduledoc """
  Helpers for sandboxing the Claude projects directory and constructing
  JSONL fixture rows / parsed `Event` structs in tests.
  """

  alias CcInspector.Sessions.Parser.Event

  @doc """
  Sandboxes `:claude_projects_dir` to a unique tmp directory for the test
  and registers cleanup on exit. Returns the directory path.
  """
  def sandbox_claude_dir! do
    dir =
      Path.join([
        System.tmp_dir!(),
        "cc_inspector_test_#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    prev = Application.get_env(:cc_inspector, :claude_projects_dir)
    Application.put_env(:cc_inspector, :claude_projects_dir, dir)

    ExUnit.Callbacks.on_exit(fn ->
      if prev do
        Application.put_env(:cc_inspector, :claude_projects_dir, prev)
      else
        Application.delete_env(:cc_inspector, :claude_projects_dir)
      end

      File.rm_rf!(dir)
    end)

    dir
  end

  @doc """
  Writes a list of JSONL records to `<dir>/<slug>/<session_id>.jsonl`.
  Returns the file path.
  """
  def write_session!(dir, slug, session_id, records) do
    project_dir = Path.join(dir, slug)
    File.mkdir_p!(project_dir)
    path = Path.join(project_dir, session_id <> ".jsonl")
    body = records |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.write!(path, body <> "\n")
    path
  end

  @doc "Append additional JSONL records to an existing session file."
  def append_session!(path, records) do
    body = records |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.write!(path, "\n" <> body <> "\n", [:append])
    path
  end

  ## ----------------------------------------------------------------
  ## Raw JSONL row builders
  ## ----------------------------------------------------------------

  def user_row(opts \\ []) do
    base("user", opts)
    |> Map.put("message", %{
      "role" => "user",
      "content" => Keyword.get(opts, :content, "Hello world")
    })
  end

  def assistant_row(opts \\ []) do
    msg =
      %{
        "role" => "assistant",
        "model" => Keyword.get(opts, :model, "claude-opus-4-7"),
        "content" => Keyword.get(opts, :content, [%{"type" => "text", "text" => "Hi"}])
      }
      |> maybe_put("id", Keyword.get(opts, :message_id))
      |> maybe_put("usage", encode_usage(Keyword.get(opts, :usage)))
      |> maybe_put("stop_reason", Keyword.get(opts, :stop_reason))

    base("assistant", opts)
    |> Map.put("message", msg)
  end

  def system_row(opts \\ []), do: base("system", opts)
  def file_history_row(opts \\ []), do: base("file-history-snapshot", opts)
  def attachment_row(opts \\ []), do: base("attachment", opts)
  def permission_mode_row(opts \\ []), do: base("permission-mode", opts)
  def queue_operation_row(opts \\ []), do: base("queue-operation", opts)
  def last_prompt_row(opts \\ []), do: base("last-prompt", opts)

  def ai_title_row(session_id, title, opts \\ []) do
    base("ai-title", opts)
    |> Map.put("aiTitle", title)
    |> Map.put("sessionId", session_id)
  end

  @doc "Build a tool_use content block."
  def tool_use_block(name, input, opts \\ []) do
    %{
      "type" => "tool_use",
      "id" => Keyword.get(opts, :id, "toolu_" <> uuid()),
      "name" => name,
      "input" => input
    }
  end

  @doc "Build a tool_result content block (lives inside a user row)."
  def tool_result_block(tool_use_id, content, opts \\ []) do
    %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id,
      "content" => content,
      "is_error" => Keyword.get(opts, :is_error, false)
    }
  end

  def text_block(text), do: %{"type" => "text", "text" => text}
  def thinking_block(text), do: %{"type" => "thinking", "thinking" => text}

  ## ----------------------------------------------------------------
  ## Typed Event builders (for pure-logic tests)
  ## ----------------------------------------------------------------

  @doc "Build an `%Event{}` of the given type with sane defaults overridable via attrs."
  def event(type, attrs \\ []) do
    defaults = %Event{
      uuid: uuid(),
      type: type,
      timestamp: utc_now(),
      is_meta: false,
      is_sidechain: false
    }

    Enum.reduce(attrs, defaults, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  def usage(opts \\ []) do
    %{
      input: Keyword.get(opts, :input, 0),
      output: Keyword.get(opts, :output, 0),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_creation: Keyword.get(opts, :cache_creation, 0)
    }
  end

  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  def uuid, do: Integer.to_string(System.unique_integer([:positive]))

  ## ----------------------------------------------------------------
  ## Internal
  ## ----------------------------------------------------------------

  defp base(type, opts) do
    %{
      "uuid" => Keyword.get(opts, :uuid, uuid()),
      "parentUuid" => Keyword.get(opts, :parent_uuid),
      "type" => type,
      "timestamp" => Keyword.get(opts, :timestamp, iso(utc_now())),
      "cwd" => Keyword.get(opts, :cwd),
      "gitBranch" => Keyword.get(opts, :git_branch),
      "sessionId" => Keyword.get(opts, :session_id),
      "version" => Keyword.get(opts, :version),
      "isMeta" => Keyword.get(opts, :is_meta, false),
      "isSidechain" => Keyword.get(opts, :is_sidechain, false),
      "promptId" => Keyword.get(opts, :prompt_id)
    }
  end

  defp encode_usage(nil), do: nil

  defp encode_usage(map) when is_map(map) do
    %{
      "input_tokens" => Map.get(map, :input, 0),
      "output_tokens" => Map.get(map, :output, 0),
      "cache_read_input_tokens" => Map.get(map, :cache_read, 0),
      "cache_creation_input_tokens" => Map.get(map, :cache_creation, 0)
    }
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
