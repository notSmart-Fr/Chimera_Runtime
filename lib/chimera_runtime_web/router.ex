defmodule ChimeraRuntimeWeb.Router do
  use ChimeraRuntimeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChimeraRuntimeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Control_Room access pipeline. DEMO POSTURE: this pipeline intentionally
  # contains NO authentication plug, so /control-room is open to anyone who can
  # reach the server. If authentication is ever required, add it here (and only
  # here) so every Control_Room route is protected from a single place.
  pipeline :control_room_access do
  end

  # MCP pipeline: no session and no CSRF. McpGuard (size, Origin, token) runs
  # before McpLimits (caps the list_plugins limit argument).
  pipeline :mcp do
    plug ChimeraRuntimeWeb.Plugs.McpGuard
    plug ChimeraRuntimeWeb.Plugs.McpLimits
  end

  scope "/" do
    pipe_through :mcp

    # `forward` escapes its options at compile time, so allowed_origins cannot be a
    # config-read list. An external capture is escapable and reads the same
    # `:mcp` `allowed_origins` config as McpGuard at run time.
    forward "/mcp", AshAi.Mcp.Router,
      tools: [:list_plugins, :inspect_execution_metrics, :run_plugin, :quarantine_plugin],
      otp_app: :chimera_runtime,
      allowed_origins: &ChimeraRuntimeWeb.Plugs.McpGuard.origin_allowed?/1
  end

  scope "/", ChimeraRuntimeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", ChimeraRuntimeWeb do
    pipe_through [:browser, :control_room_access]

    live "/control-room", DashboardLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ChimeraRuntimeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:chimera_runtime, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ChimeraRuntimeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
