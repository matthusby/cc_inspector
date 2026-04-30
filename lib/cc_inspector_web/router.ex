defmodule CcInspectorWeb.Router do
  use CcInspectorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CcInspectorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CcInspectorWeb do
    pipe_through :browser

    live "/", SessionsLive, :index
    live "/sessions/:id", SessionLive, :show
  end

  if Application.compile_env(:cc_inspector, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CcInspectorWeb.Telemetry
    end
  end
end
