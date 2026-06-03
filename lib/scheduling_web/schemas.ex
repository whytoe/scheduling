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

  defmodule Diagnosis do
    @moduledoc "A single diagnosis row with its default required capabilities."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Diagnosis",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string, description: "Unique display name"},
        code: %Schema{type: :string, nullable: true, description: "Optional unique short code (e.g. \"DX-FRAC\")"},
        capabilities: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.Capability,
          description: "Default required capabilities for this diagnosis"
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :capabilities, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Stroke Workup",
        "code" => "DX-STRK",
        "capabilities" => [],
        "inserted_at" => "2026-06-01T12:34:56Z",
        "updated_at" => "2026-06-01T12:34:56Z"
      }
    })
  end

  defmodule DiagnosisList do
    @moduledoc "A list of diagnoses."
    require OpenApiSpex
    OpenApiSpex.schema(%{
      title: "DiagnosisList",
      type: :array,
      items: SchedulingWeb.Schemas.Diagnosis
    })
  end

  defmodule DiagnosisRequest do
    @moduledoc "Request body for creating or updating a diagnosis."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DiagnosisRequest",
      type: :object,
      properties: %{
        diagnosis: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Unique display name (1–255 chars)"},
            code: %Schema{type: :string, nullable: true, description: "Optional unique short code"},
            capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description: "Capability ids that become this diagnosis's default required capabilities. Omit to leave existing associations unchanged; pass [] to clear them."
            }
          },
          required: [:name]
        }
      },
      required: [:diagnosis],
      example: %{"diagnosis" => %{"name" => "Stroke Workup", "code" => "DX-STRK", "capability_ids" => [1, 2]}}
    })
  end

  defmodule Patient do
    @moduledoc "A single patient row."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Patient",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string, description: "Display name"},
        external_id: %Schema{type: :string, nullable: true, description: "Optional id assigned by the upstream check-in app"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Jane Doe",
        "external_id" => "checkin-7a3f",
        "inserted_at" => "2026-06-01T12:34:56Z",
        "updated_at" => "2026-06-01T12:34:56Z"
      }
    })
  end

  defmodule PatientList do
    @moduledoc "A list of patients."
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "PatientList", type: :array, items: SchedulingWeb.Schemas.Patient})
  end

  defmodule PatientRequest do
    @moduledoc "Request body for creating or updating a patient."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PatientRequest",
      type: :object,
      properties: %{
        patient: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Display name (1–255 chars)"},
            external_id: %Schema{type: :string, nullable: true, description: "Optional unique check-in id"}
          },
          required: [:name]
        }
      },
      required: [:patient],
      example: %{"patient" => %{"name" => "Jane Doe", "external_id" => "checkin-7a3f"}}
    })
  end

  defmodule Office do
    @moduledoc "A single office with its current capabilities."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Office",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string, description: "Unique display name"},
        intake_capacity: %Schema{type: :integer, minimum: 0, description: "Concurrent patient capacity"},
        capabilities: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.Capability,
          description: "Capabilities this office provides"
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :intake_capacity, :capabilities, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Room 101",
        "intake_capacity" => 2,
        "capabilities" => [],
        "inserted_at" => "2026-06-01T12:34:56Z",
        "updated_at" => "2026-06-01T12:34:56Z"
      }
    })
  end

  defmodule OfficeList do
    @moduledoc "A list of offices."
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "OfficeList", type: :array, items: SchedulingWeb.Schemas.Office})
  end

  defmodule OfficeRequest do
    @moduledoc "Request body for creating or updating an office."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "OfficeRequest",
      type: :object,
      properties: %{
        office: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Unique display name (1–255 chars)"},
            intake_capacity: %Schema{type: :integer, minimum: 0},
            capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description: "Capability ids this office provides. Omit to leave associations unchanged; pass [] to clear them."
            }
          },
          required: [:name, :intake_capacity]
        }
      },
      required: [:office],
      example: %{"office" => %{"name" => "Room 101", "intake_capacity" => 2, "capability_ids" => [1, 2]}}
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
