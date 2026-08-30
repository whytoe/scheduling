defmodule SchedulingWeb.Router do
  use SchedulingWeb, :router

  alias SchedulingWeb.Plugs.ApiAuth
  alias SchedulingWeb.Plugs.BrowserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SchedulingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BrowserAuth, :fetch_current_scope
  end

  # Signed-in operators only. `:browser` has already put `current_scope` on the
  # conn; this turns its absence into a redirect through the IdP.
  pipeline :require_operator do
    plug BrowserAuth, :require_authenticated
  end

  # Catalog CRUD (offices, capabilities, diagnoses) reshapes how every future
  # patient is routed, so it is admin-gated rather than open to any operator.
  pipeline :require_admin do
    plug BrowserAuth, :require_authenticated
    plug BrowserAuth, {:require_role, ["admin"]}
  end

  # Back-channel logout is posted by the identity provider, server-to-server.
  # It gets its own pipeline because it fits neither of the others: no session,
  # no cookies, and therefore no CSRF token — running it through `:browser`
  # would mean weakening `protect_from_forgery` for everything. Authentication
  # is the signature on the logout token itself, checked in the controller.
  pipeline :oidc_backchannel do
    plug :accepts, ["json", "html"]
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SchedulingWeb.ApiSpec
  end

  # Reads: any recognised role.
  pipeline :api_read do
    plug ApiAuth, :require_read
  end

  # Writes: operator or service (admin implicitly). This is the pipeline the
  # intake bridge and the check-in app authenticate against.
  pipeline :api_write do
    plug ApiAuth, :require_write
  end

  # Catalog and subscription management over the API — same bar as the UI.
  pipeline :api_admin do
    plug ApiAuth, :require_admin
  end

  # Public: the SSO handshake itself, plus the page a signed-out operator
  # lands on. Nothing here may require a scope — that would be a redirect loop.
  scope "/", SchedulingWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/login", AuthController, :login
    get "/auth/callback", AuthController, :callback
    get "/auth/logout", AuthController, :logout
    get "/auth/signed_out", AuthController, :signed_out
  end

  scope "/", SchedulingWeb do
    pipe_through :oidc_backchannel

    post "/auth/backchannel-logout", BackchannelLogoutController, :create
  end

  # The operator surface. `live_session` re-runs the auth hook on every mount,
  # including the websocket one, so a socket cannot outlive its authorization.
  scope "/", SchedulingWeb do
    pipe_through [:browser, :require_operator]

    live_session :authenticated,
      on_mount: [{SchedulingWeb.AuthHooks, :require_authenticated}] do
      live "/board", BoardLive.Index, :index

      live "/queue", QueueLive.Index, :index

      live "/decisions", RoutingDecisionLive.Index, :index

      live "/visit_events", VisitEventLive.Index, :index

      live "/visits", VisitLive.Index, :index
    end
  end

  # Catalog administration. A separate `live_session` because the role bar is
  # higher: LiveView only skips re-running hooks within one session, so this
  # boundary cannot be crossed by live navigation from the operator screens.
  scope "/", SchedulingWeb do
    pipe_through [:browser, :require_admin]

    live_session :admin,
      on_mount: [{SchedulingWeb.AuthHooks, {:require_role, ["admin"]}}] do
      live "/offices", OfficeLive.Index, :index
      live "/offices/new", OfficeLive.Index, :new
      live "/offices/:id/edit", OfficeLive.Index, :edit

      live "/capabilities", CapabilityLive.Index, :index
      live "/capabilities/new", CapabilityLive.Index, :new
      live "/capabilities/:id/edit", CapabilityLive.Index, :edit

      live "/diagnoses", DiagnosisLive.Index, :index
      live "/diagnoses/new", DiagnosisLive.Index, :new
      live "/diagnoses/:id/edit", DiagnosisLive.Index, :edit

      live "/availability", AvailabilityLive.Index, :index
      live "/availability/new", AvailabilityLive.Index, :new
      live "/availability/:id/edit", AvailabilityLive.Index, :edit
    end
  end

  # Spec-discovery + health stay UNVERSIONED. They evolve independently of
  # the API surface and clients hit them before they know which version to
  # use. Everything else lives under /api/v1.
  scope "/api", SchedulingWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # ---------------------------------------------------------------------------
  # /api/v1 — grouped by the role each call requires, not by resource.
  #
  # Splitting by resource would mean two scope blocks per resource (reads and
  # writes need different pipelines), so grouping by permission keeps the file
  # readable and puts the access rule in one place per tier instead of eleven.
  # `docs/integrations.md` documents the surface resource-by-resource.
  # ---------------------------------------------------------------------------

  # READ — any recognised role (`viewer`, `operator`, `service`, `admin`).
  scope "/api/v1", SchedulingWeb do
    pipe_through [:api, :api_read]

    scope "/", Api do
      get "/capabilities", CapabilityController, :index
      get "/capabilities/:id", CapabilityController, :show

      get "/diagnoses", DiagnosisController, :index
      get "/diagnoses/:id", DiagnosisController, :show

      get "/patients", PatientController, :index
      get "/patients/:id", PatientController, :show

      get "/offices", OfficeController, :index
      get "/offices/:id", OfficeController, :show

      get "/queue_entries", QueueEntryController, :index
      get "/queue_entries/:id", QueueEntryController, :show

      get "/handoffs", HandoffController, :index
      get "/handoffs/:id", HandoffController, :show

      get "/routing_decisions", RoutingDecisionController, :index
      get "/routing_decisions/:id", RoutingDecisionController, :show

      get "/visit_events", VisitEventController, :index
      get "/visit_events/:id", VisitEventController, :show

      get "/visits", VisitController, :index
      get "/visits/:id", VisitController, :show

      get "/appointments", AppointmentController, :index
      get "/appointments/:id", AppointmentController, :show

      # Availability search. Reading a slot as `open` is not a reservation —
      # two clients can see the same one and only one wins the booking.
      get "/slots", AppointmentController, :slots
    end

    get "/board", Api.BoardController, :show
  end

  # WRITE — `operator` or `service` (and `admin`, which satisfies everything).
  # The patient-flow operations: this is what the check-in / queueing app and
  # the intake bridge call.
  scope "/api/v1", SchedulingWeb.Api, as: :api do
    pipe_through [:api, :api_write]

    post "/patients", PatientController, :create
    put "/patients/:id", PatientController, :update
    patch "/patients/:id", PatientController, :update

    post "/queue_entries", QueueEntryController, :create
    post "/queue_entries/:id/accept", QueueEntryController, :accept
    post "/queue_entries/:id/complete", QueueEntryController, :complete
    post "/queue_entries/:id/requeue", QueueEntryController, :requeue

    post "/handoffs/:id/acknowledge", HandoffController, :acknowledge

    post "/visits", VisitController, :create
    post "/visits/:id/end", VisitController, :end_visit

    post "/appointments", AppointmentController, :create
    patch "/appointments/:id", AppointmentController, :update
    put "/appointments/:id", AppointmentController, :update
    post "/appointments/:id/cancel", AppointmentController, :cancel
  end

  # ADMIN — catalog changes reshape how every future patient is routed, and a
  # webhook subscription is an outbound data path. Both are admin-only, matching
  # the UI's admin `live_session`. Patient deletion sits here for the same
  # reason: it is destructive and never part of the normal check-in flow.
  scope "/api/v1", SchedulingWeb.Api, as: :api_admin do
    pipe_through [:api, :api_admin]

    post "/capabilities", CapabilityController, :create
    put "/capabilities/:id", CapabilityController, :update
    patch "/capabilities/:id", CapabilityController, :update
    delete "/capabilities/:id", CapabilityController, :delete

    post "/diagnoses", DiagnosisController, :create
    put "/diagnoses/:id", DiagnosisController, :update
    patch "/diagnoses/:id", DiagnosisController, :update
    delete "/diagnoses/:id", DiagnosisController, :delete

    post "/offices", OfficeController, :create
    put "/offices/:id", OfficeController, :update
    patch "/offices/:id", OfficeController, :update
    delete "/offices/:id", OfficeController, :delete

    delete "/patients/:id", PatientController, :delete

    get "/webhook_subscriptions", WebhookSubscriptionController, :index
    post "/webhook_subscriptions", WebhookSubscriptionController, :create
    get "/webhook_subscriptions/:id", WebhookSubscriptionController, :show
    put "/webhook_subscriptions/:id", WebhookSubscriptionController, :update
    patch "/webhook_subscriptions/:id", WebhookSubscriptionController, :update
    delete "/webhook_subscriptions/:id", WebhookSubscriptionController, :delete
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
