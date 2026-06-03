defmodule SchedulingWeb.ApiSpec do
  @moduledoc """
  The top-level OpenAPI document for the Scheduling API.

  Served as JSON at `/api/openapi.json`. Swagger UI lives at `/api/swagger`.
  Paths are derived from the router so they stay in sync with reality —
  each `:api`-pipelined route whose controller declares `OpenApiSpex.ControllerSpecs`
  operations gets included automatically.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  alias SchedulingWeb.{Endpoint, Router}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Scheduling API",
        version: Application.spec(:scheduling, :vsn) |> to_string(),
        description: """
        Operational HTTP API for the Scheduling app. Today this covers the
        health endpoint used by container orchestrators; resource APIs
        (offices, capabilities, queue, decisions) are surfaced via LiveView
        in the browser and will be added here as JSON endpoints are
        introduced.
        """
      },
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
