defmodule CcInspector.Sessions.OpenCodeTest do
  # Not async: the snapshot lives in one process-wide cache entry.
  use ExUnit.Case, async: false

  alias CcInspector.Sessions.{Cache, OpenCode, Summary}

  setup do
    clear = fn ->
      Cache.invalidate_provider(:opencode_summaries)
      Cache.invalidate_provider(:opencode_usage)
      Cache.invalidate_provider(:opencode_error)
    end

    clear.()
    on_exit(clear)
  end

  describe "list_summaries_result/0" do
    test "reports an empty list, not a failure, before the first refresh lands" do
      assert OpenCode.list_summaries_result() == {:ok, []}
    end

    test "serves the snapshot the last refresh stored" do
      summary = %Summary{provider: :opencode, session_id: "ses_1"}
      Cache.put_provider(:opencode_summaries, [summary])

      assert OpenCode.list_summaries_result() == {:ok, [summary]}
    end

    test "reports the recorded reason once a refresh has failed" do
      Cache.put_provider(:opencode_error, "command exited with status 1")

      assert OpenCode.list_summaries_result() == {:error, "command exited with status 1"}
    end

    # A failed refresh leaves the last good snapshot in place, so OpenCode
    # sessions never blink out of the index when the database can't be read.
    test "keeps serving the previous snapshot after a refresh fails" do
      summary = %Summary{provider: :opencode, session_id: "ses_1"}
      Cache.put_provider(:opencode_summaries, [summary])
      Cache.put_provider(:opencode_error, "boom")

      assert OpenCode.list_summaries_result() == {:ok, [summary]}
    end
  end

  describe "usage_by_session/0" do
    test "is empty before the first refresh lands" do
      assert OpenCode.usage_by_session() == %{}
    end

    test "serves the buckets the last refresh stored" do
      buckets = %{"ses_1" => %{496_167 => %{input: 5, output: 1}}}
      Cache.put_provider(:opencode_usage, buckets)

      assert OpenCode.usage_by_session() == buckets
    end
  end
end
