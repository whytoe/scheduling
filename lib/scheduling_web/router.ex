defmodule SchedulingWeb.Router do
  use SchedulingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SchedulingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SchedulingWeb.ApiSpec
  end

  scope "/", SchedulingWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/board", BoardLive.Index, :index

    live "/queue", QueueLive.Index, :index

    live "/decisions", RoutingDecisionLive.Index, :index

    live "/offices", OfficeLive.Index, :index
    live "/offices/new", OfficeLive.Index, :new
    live "/offices/:id/edit", OfficeLive.Index, :edit

    live "/capabilities", CapabilityLive.Index, :index
    live "/capabilities/new", CapabilityLive.Index, :new
    live "/capabilities/:id/edit", CapabilityLive.Index, :edit
  end

  scope "/api", SchedulingWeb do
    pipe_through :api

    get "/health", HealthController, :index

    scope "/capabilities", Api do
      get "/", CapabilityController, :index
      post "/", CapabilityController, :create
      get "/:id", CapabilityController, :show
      put "/:id", CapabilityController, :update
      patch "/:id", CapabilityController, :update
      delete "/:id", CapabilityController, :delete
    end

    scope "/diagnoses", Api do
      get "/", DiagnosisController, :index
      post "/", DiagnosisController, :create
      get "/:id", DiagnosisController, :show
      put "/:id", DiagnosisController, :update
      patch "/:id", DiagnosisController, :update
      delete "/:id", DiagnosisController, :delete
    end

    scope "/patients", Api do
      get "/", PatientController, :index
      post "/", PatientController, :create
      get "/:id", PatientController, :show
      put "/:id", PatientController, :update
      patch "/:id", PatientController, :update
      delete "/:id", PatientController, :delete
    end

    scope "/offices", Api do
      get "/", OfficeController, :index
      post "/", OfficeController, :create
      get "/:id", OfficeController, :show
      put "/:id", OfficeController, :update
      patch "/:id", OfficeController, :update
      delete "/:id", OfficeController, :delete
    end

    scope "/queue_entries", Api do
      get "/", QueueEntryController, :index
      post "/", QueueEntryController, :create
      get "/:id", QueueEntryController, :show
      post "/:id/accept", QueueEntryController, :accept
      post "/:id/complete", QueueEntryController, :complete
      post "/:id/requeue", QueueEntryController, :requeue
    end

    scope "/handoffs", Api do
      get "/", HandoffController, :index
      get "/:id", HandoffController, :show
      post "/:id/acknowledge", HandoffController, :acknowledge
    end

    scope "/routing_decisions", Api do
      get "/", RoutingDecisionController, :index
      get "/:id", RoutingDecisionController, :show
    end

    scope "/visits", Api do
      get "/", VisitController, :index
      post "/", VisitController, :create
      get "/:id", VisitController, :show
      post "/:id/end", VisitController, :end_visit
    end

    get "/board", Api.BoardController, :show
  end

  scope "/api" do
    pipe_through :api

    # Serves the rendered OpenAPI document. Consumers point clients at this URL.
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, :show
  end

  scope "/" do
    pipe_through :browser

    # Interactive Swagger UI for exploring the API in a browser.
    get "/api/swagger", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:scheduling, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SchedulingWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
