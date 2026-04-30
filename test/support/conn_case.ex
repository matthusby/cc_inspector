defmodule CcInspectorWeb.ConnCase do
  @moduledoc """
  Test case for tests that require setting up a connection or driving
  a LiveView via `Phoenix.LiveViewTest`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CcInspectorWeb.Endpoint

      use CcInspectorWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import CcInspectorWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
