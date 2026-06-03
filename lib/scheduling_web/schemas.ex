defmodule SchedulingWeb.Schemas do
  @moduledoc """
  OpenAPI schema modules for the Scheduling API.

  Each nested module defines a schema via `OpenApiSpex.schema/1` and is
  referenced by controller `operation` declarations. Add new schemas here
  as new JSON endpoints are introduced.
  """

  defmodule HealthResponse do
    @moduledoc "Health probe response body."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      description: "Reports whether the app and its database are reachable.",
      type: :object,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ["ok", "degraded"],
          description:
            "`ok` when the app is up and `SELECT 1` against the database succeeded. " <>
              "`degraded` when the database query failed (HTTP 503)."
        }
      },
      required: [:status],
      example: %{"status" => "ok"}
    })
  end
end
