defmodule SchedulingWeb.Schemas do
  @moduledoc """
  OpenAPI schema modules for the Scheduling API.

  Each nested module defines a schema via `OpenApiSpex.schema/1` and is
  referenced by controller `operation` declarations. Add new schemas here
  as new JSON endpoints are introduced.
  """

  defmodule NotFoundError do
    @moduledoc "Returned with HTTP 404 when a resource id can't be found."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "NotFoundError",
      type: :object,
      properties: %{error: %Schema{type: :string, description: "Human-readable error message"}},
      required: [:error],
      example: %{"error" => "not_found"}
    })
  end

  defmodule ValidationError do
    @moduledoc """
    Returned with HTTP 422 when request body fails validation. `errors` is a
    map from field name to a list of failure messages — same shape Ecto
    changeset traversal produces.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ValidationError",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      },
      required: [:errors],
      example: %{"errors" => %{"name" => ["can't be blank"]}}
    })
  end

  defmodule Capability do
    @moduledoc "A single capability row."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Capability",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Server-assigned id"},
        name: %Schema{type: :string, description: "Unique name, e.g. \"Computed Tomography (CT)\""},
        description: %Schema{type: :string, nullable: true, description: "Optional free-form description"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Dialysis",
        "description" => nil,
        "inserted_at" => "2026-06-01T12:34:56Z",
        "updated_at" => "2026-06-01T12:34:56Z"
      }
    })
  end

  defmodule CapabilityList do
    @moduledoc "A list of capabilities, sorted by name."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CapabilityList",
      type: :array,
      items: SchedulingWeb.Schemas.Capability
    })
  end

  defmodule CapabilityRequest do
    @moduledoc "Request body for creating or updating a capability."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "CapabilityRequest",
      type: :object,
      properties: %{
        capability: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Unique name (1–255 chars)"},
            description: %Schema{type: :string, nullable: true}
          },
          required: [:name]
        }
      },
      required: [:capability],
      example: %{"capability" => %{"name" => "Dialysis", "description" => nil}}
    })
  end

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
