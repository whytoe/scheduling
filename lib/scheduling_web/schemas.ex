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
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["not_found"]},
            message: %Schema{type: :string, description: "Human-readable summary"}
          },
          required: [:code, :message]
        }
      },
      required: [:error],
      example: %{"error" => %{"code" => "not_found", "message" => "Resource not found"}}
    })
  end

  defmodule ValidationError do
    @moduledoc """
    Returned with HTTP 422 when the request body fails validation. The
    field → messages map (the shape Ecto changeset traversal produces) is
    carried under `error.details.fields`.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ValidationError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["validation_failed"]},
            message: %Schema{type: :string},
            details: %Schema{
              type: :object,
              properties: %{
                fields: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :array, items: %Schema{type: :string}},
                  description: "Map of field name to a list of failure messages"
                }
              },
              required: [:fields]
            }
          },
          required: [:code, :message, :details]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "validation_failed",
          "message" => "One or more fields are invalid",
          "details" => %{"fields" => %{"name" => ["can't be blank"]}}
        }
      }
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
        name: %Schema{
          type: :string,
          description: "Unique name, e.g. \"Computed Tomography (CT)\""
        },
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Optional free-form description"
        },
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
        code: %Schema{
          type: :string,
          nullable: true,
          description: "Optional unique short code (e.g. \"DX-FRAC\")"
        },
        capabilities: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.Capability,
          description: "Default required capabilities for this diagnosis"
        },
        required_form_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Intake form types that must be completed (status=completed AND not flagged) before a patient with this diagnosis can be assigned to an office."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :capabilities, :required_form_types, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Stroke Workup",
        "code" => "DX-STRK",
        "capabilities" => [],
        "required_form_types" => ["stroke-consent"],
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
            code: %Schema{
              type: :string,
              nullable: true,
              description: "Optional unique short code"
            },
            capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description:
                "Capability ids that become this diagnosis's default required capabilities. Omit to leave existing associations unchanged; pass [] to clear them."
            },
            required_form_types: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Intake form types required for compliance. Pass [] to clear."
            }
          },
          required: [:name]
        }
      },
      required: [:diagnosis],
      example: %{
        "diagnosis" => %{
          "name" => "Stroke Workup",
          "code" => "DX-STRK",
          "capability_ids" => [1, 2],
          "required_form_types" => ["stroke-consent"]
        }
      }
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
        name: %Schema{
          type: :string,
          description:
            "Display name, cached from ac-core. This system does not own it — treat ac-core as authoritative."
        },
        core_patient_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "This patient's id in ac-core, the platform's registry — the identity of record. Null on rows created before the projection existed; they populate on next touch. Prefer this over `client_id` for new integrations."
        },
        client_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "Scheduling-owned UUID, auto-generated if not supplied. **Deprecated** as an inter-service reference in favour of `core_patient_id`: it names a row in this database, not the person every system shares. Still generated and still unique, so existing consumers keep working."
        },
        external_id: %Schema{
          type: :string,
          nullable: true,
          description: "Optional id assigned by the upstream check-in / queueing app"
        },
        intake_patient_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "UUID this patient has in the intake-form system. Used at accept time to look up their completed forms."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :client_id, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Jane Doe",
        "core_patient_id" => "3f2b8c1d-7a45-4e29-b0c6-4d8e1f9a2b73",
        "client_id" => "9b1c4a3e-2f5d-4b8a-9c7e-1a3b5c7d9e2f",
        "external_id" => "checkin-7a3f",
        "intake_patient_id" => "5e1f2c8a-1d3b-4ee9-9a64-8e3b6cf21e10",
        "inserted_at" => "2026-06-01T12:34:56Z",
        "updated_at" => "2026-06-01T12:34:56Z"
      }
    })
  end

  defmodule PatientList do
    @moduledoc "A list of patients."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PatientList",
      type: :array,
      items: SchedulingWeb.Schemas.Patient
    })
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
            core_patient_id: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description:
                "Optional unique ac-core registry id. Supplying it links this row to the registry; the name is then a cache of what ac-core holds."
            },
            client_id: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description:
                "Scheduling-owned UUID. Optional on create: server generates one if omitted. Deprecated in favour of `core_patient_id`."
            },
            external_id: %Schema{
              type: :string,
              nullable: true,
              description: "Optional unique check-in id"
            },
            intake_patient_id: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description: "Optional unique intake-form-system UUID"
            }
          },
          required: [:name]
        }
      },
      required: [:patient],
      example: %{
        "patient" => %{
          "name" => "Jane Doe",
          "external_id" => "checkin-7a3f",
          "intake_patient_id" => "5e1f2c8a-1d3b-4ee9-9a64-8e3b6cf21e10"
        }
      }
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
        intake_capacity: %Schema{
          type: :integer,
          minimum: 0,
          description: "Concurrent patient capacity"
        },
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
              description:
                "Capability ids this office provides. Omit to leave associations unchanged; pass [] to clear them."
            }
          },
          required: [:name, :intake_capacity]
        }
      },
      required: [:office],
      example: %{
        "office" => %{"name" => "Room 101", "intake_capacity" => 2, "capability_ids" => [1, 2]}
      }
    })
  end

  defmodule Visit do
    @moduledoc "A patient encounter; potentially spans multiple queue entries."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Visit",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        patient_id: %Schema{type: :integer},
        status: %Schema{type: :string, enum: ["active", "ended"]},
        started_at: %Schema{type: :string, format: :"date-time"},
        ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :patient_id, :status, :started_at, :inserted_at, :updated_at]
    })
  end

  defmodule VisitList do
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "VisitList", type: :array, items: SchedulingWeb.Schemas.Visit})
  end

  defmodule VisitRequest do
    @moduledoc "Request body for creating a visit."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "VisitRequest",
      type: :object,
      properties: %{
        visit: %Schema{
          type: :object,
          properties: %{
            patient_id: %Schema{type: :integer, description: "Patient whose encounter this is"},
            started_at: %Schema{
              type: :string,
              format: :"date-time",
              description: "Defaults to now if omitted"
            }
          },
          required: [:patient_id]
        }
      },
      required: [:visit]
    })
  end

  defmodule QueueEntry do
    @moduledoc "A queue entry — a patient waiting for, or currently receiving, service."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "QueueEntry",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        status: %Schema{
          type: :string,
          enum: ["waiting", "assigned", "in_service", "completed"],
          description:
            "Lifecycle status; entries in `assigned` and `in_service` consume office capacity"
        },
        priority: %Schema{type: :integer, minimum: 0, description: "Higher = served sooner"},
        patient: %Schema{nullable: true, allOf: [SchedulingWeb.Schemas.Patient]},
        patient_id: %Schema{type: :integer},
        assigned_office_id: %Schema{type: :integer, nullable: true},
        visit_id: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Parent Visit this entry belongs to (set when created via the queueing service's sign-in flow)"
        },
        required_capabilities: %Schema{type: :array, items: SchedulingWeb.Schemas.Capability},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :status,
        :priority,
        :patient_id,
        :required_capabilities,
        :inserted_at,
        :updated_at
      ]
    })
  end

  defmodule QueueEntryList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "QueueEntryList",
      type: :array,
      items: SchedulingWeb.Schemas.QueueEntry
    })
  end

  defmodule QueueEntryCreateRequest do
    @moduledoc "Request body for creating a queue entry."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "QueueEntryCreateRequest",
      type: :object,
      properties: %{
        queue_entry: %Schema{
          type: :object,
          properties: %{
            patient_id: %Schema{type: :integer, description: "Patient this entry represents"},
            service_code: %Schema{
              type: :string,
              nullable: true,
              description:
                "Optional. **The form external callers should use, and transient input — not stored.** Names a routing template by its catalog `code`, which is a stable contract key rather than a row id, and may be opaque (`svc_7a2f`). Expanded to that template's default capabilities, which are recorded on the entry; the code itself is discarded. Scheduling keeps the equipment requirement, never the service that implied it. Takes precedence over `diagnosis_id`; ignored when `required_capability_ids` is given."
            },
            diagnosis_id: %Schema{
              type: :integer,
              nullable: true,
              description:
                "Optional. **Transient input, not stored**, and a row id rather than a contract key — prefer `service_code`. Expanded to that template's default capabilities, which are recorded on the entry; the reference itself is discarded. Ignored when `required_capability_ids` or `service_code` is given."
            },
            visit_id: %Schema{
              type: :integer,
              nullable: true,
              description: "Parent Visit. Set by the queueing service's sign-in flow."
            },
            priority: %Schema{type: :integer, minimum: 0, description: "Defaults to 0"},
            compliance_ref: %Schema{
              type: :string,
              nullable: true,
              description:
                "Opaque reference the intake-form system resolves to the forms this encounter requires. Scheduling passes it through and never learns the form types. Omit to skip the compliance gate. **Write-only** — it is not returned on QueueEntry reads, only in the `compliance_failed` error details where it is actionable."
            },
            required_capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description:
                "Capability ids this patient requires. Takes precedence over `diagnosis_id` when both are supplied."
            }
          },
          required: [:patient_id]
        }
      },
      required: [:queue_entry]
    })
  end

  defmodule QueueEntryAcceptRequest do
    @moduledoc "Optional body for accept; carries audit metadata."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "QueueEntryAcceptRequest",
      type: :object,
      properties: %{
        accepted_by: %Schema{
          type: :string,
          nullable: true,
          description: "User attribution recorded in the routing decision audit log"
        }
      }
    })
  end

  defmodule QueueEntryRequeueRequest do
    @moduledoc "Optional body for requeue; lets you swap the required capabilities."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "QueueEntryRequeueRequest",
      type: :object,
      properties: %{
        required_capability_ids: %Schema{
          type: :array,
          items: %Schema{type: :integer},
          description:
            "Capabilities the new service requires. Omit to keep the current set; pass [] to clear."
        }
      }
    })
  end

  defmodule ComplianceFailedError do
    @moduledoc """
    Returned when the intake-form system reports the patient has not satisfied
    the forms this encounter requires.

    Names the opaque `compliance_ref` so an operator can look the encounter up
    in the intake system — **not** the form types behind it. Those are health
    data; scheduling neither stores nor transmits them. See
    `docs/data-boundary.md`.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ComplianceFailedError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["compliance_failed"]},
            message: %Schema{type: :string},
            details: %Schema{
              type: :object,
              nullable: true,
              properties: %{
                compliance_ref: %Schema{
                  type: :string,
                  description:
                    "The entry's opaque compliance reference; resolve it in the intake system to see which forms are outstanding. Absent when the entry carries no reference."
                }
              }
            }
          },
          required: [:code, :message]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "compliance_failed",
          "message" => "The patient hasn't completed every required intake form",
          "details" => %{"compliance_ref" => "enc_01HV3K7Q"}
        }
      }
    })
  end

  defmodule ComplianceUnavailableError do
    @moduledoc "Returned when the intake-form system can't be reached to verify compliance. Fail-closed by design."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ComplianceUnavailableError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["compliance_unavailable"]},
            message: %Schema{type: :string},
            details: %Schema{
              type: :object,
              properties: %{
                reason: %Schema{
                  type: :string,
                  description: "Inspect of the underlying transport error"
                }
              },
              required: [:reason]
            }
          },
          required: [:code, :message, :details]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "compliance_unavailable",
          "message" =>
            "The intake-form system is unreachable; booking is blocked until it recovers",
          "details" => %{"reason" => "{:http_status, 401, %{...}}"}
        }
      }
    })
  end

  defmodule Appointment do
    @moduledoc """
    A patient booked into a run of consecutive slots on one office.

    Carries the **resolved equipment requirement** and never the service that
    implied it — see the `required_capabilities` and `binding` descriptions.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Appointment",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        status: %Schema{
          type: :string,
          enum: ["booked", "arrived", "completed", "cancelled"],
          description: "Lifecycle status"
        },
        binding: %Schema{
          type: :string,
          enum: ["committed", "provisional"],
          description:
            "**Derived, not chosen** — it is not a confidence level and does not mean the booking is unconfirmed. " <>
              "`committed` means exactly one office can provide the required capabilities, so there is no routing " <>
              "decision left to make and the patient goes straight to that room on arrival. `provisional` means " <>
              "several offices could serve it, so the best-fit matcher picks one at arrival and **may place the " <>
              "patient in a different room than the reserved slots suggest**. Both are equally firm reservations of time."
        },
        patient_id: %Schema{type: :integer},
        external_ref: %Schema{
          type: :string,
          nullable: true,
          description:
            "The caller's idempotency key, echoed back. Booking twice with the same value returns the original appointment."
        },
        office_id: %Schema{
          type: :integer,
          nullable: true,
          description:
            "The office whose slots are reserved. For a `provisional` appointment this is where the time is held, " <>
              "not a guarantee of where the patient will be seen."
        },
        starts_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Earliest reserved slot's start. Derived from the slots, not stored."
        },
        ends_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Latest reserved slot's end. Derived from the slots, not stored."
        },
        required_capabilities: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.Capability,
          description:
            "The equipment this appointment needs. Note there is no service or diagnosis field: the service code " <>
              "is expanded to these at booking and then discarded, so scheduling records what the patient needs " <>
              "and never why."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status, :binding, :patient_id, :inserted_at, :updated_at]
    })
  end

  defmodule AppointmentList do
    @moduledoc "A list of appointments."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AppointmentList",
      type: :array,
      items: SchedulingWeb.Schemas.Appointment
    })
  end

  defmodule AppointmentCreateRequest do
    @moduledoc "Request body for booking an appointment."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AppointmentCreateRequest",
      type: :object,
      properties: %{
        appointment: %Schema{
          type: :object,
          properties: %{
            patient_id: %Schema{type: :integer, description: "Patient to book"},
            service_code: %Schema{
              type: :string,
              nullable: true,
              description:
                "**The form external callers should use.** Names a routing template by its catalog `code` — a " <>
                  "stable contract key rather than a row id, and one that may be opaque (`svc_7a2f`). Expanded to " <>
                  "that template's default capabilities and its duration, which together decide how many consecutive " <>
                  "slots are reserved; the code itself is **not stored**. Supply this or `required_capability_ids`."
            },
            required_capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description:
                "Explicit equipment requirement, as an alternative to `service_code`. Takes precedence when both " <>
                  "are given. With no service there is no duration, so a single slot is reserved."
            },
            from: %Schema{
              type: :string,
              format: :"date-time",
              nullable: true,
              description: "Earliest acceptable start. Defaults to now."
            },
            external_ref: %Schema{
              type: :string,
              nullable: true,
              description:
                "Idempotency key. Booking again with the same value returns the original appointment rather than " <>
                  "creating a second one — safe to retry a request whose response you did not see."
            }
          },
          required: [:patient_id]
        }
      },
      required: [:appointment],
      example: %{
        "appointment" => %{
          "patient_id" => 1,
          "service_code" => "svc_7a2f",
          "from" => "2026-09-07T09:00:00Z",
          "external_ref" => "booking-4821"
        }
      }
    })
  end

  defmodule AppointmentRescheduleRequest do
    @moduledoc "Request body for rescheduling. Changes when, never what."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AppointmentRescheduleRequest",
      type: :object,
      properties: %{
        appointment: %Schema{
          type: :object,
          properties: %{
            from: %Schema{
              type: :string,
              format: :"date-time",
              nullable: true,
              description:
                "Earliest acceptable new start. The appointment keeps its capabilities and its length — the run " <>
                  "it currently holds is what defines how long it is — and its `binding` is re-derived, since the " <>
                  "set of offices able to serve it may have changed since it was booked."
            }
          }
        }
      },
      required: [:appointment],
      example: %{"appointment" => %{"from" => "2026-09-07T14:00:00Z"}}
    })
  end

  defmodule Slot do
    @moduledoc "One unit of bookable capacity on an office."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Slot",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        office_id: %Schema{type: :integer},
        availability_rule_id: %Schema{type: :integer, nullable: true},
        appointment_id: %Schema{
          type: :integer,
          nullable: true,
          description: "Set when the slot is reserved"
        },
        starts_at: %Schema{type: :string, format: :"date-time", description: "UTC"},
        ends_at: %Schema{type: :string, format: :"date-time", description: "UTC"},
        status: %Schema{
          type: :string,
          enum: ["open", "blocked", "booked"],
          description:
            "`open` is bookable. `blocked` is withheld — a room closed for cleaning. `booked` is taken. " <>
              "Blocked and booked are distinct because a closed room and a full one are different facts."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :office_id, :starts_at, :ends_at, :status]
    })
  end

  defmodule SlotList do
    @moduledoc "A list of slots."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SlotList",
      type: :array,
      items: SchedulingWeb.Schemas.Slot
    })
  end

  defmodule BookingConflictError do
    @moduledoc """
    Returned with HTTP 409 when the requested time could not be reserved.

    **Both codes are worth retrying**, which is what separates them from the
    422 booking errors. `slots_taken` means a concurrent booking won the race
    for the same slots; `no_available_slots` means nothing free was found in
    the requested window, so retrying with a different `from` may succeed.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "BookingConflictError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["slots_taken", "no_available_slots"]},
            message: %Schema{type: :string}
          },
          required: [:code, :message]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "no_available_slots",
          "message" => "No run of consecutive open slots long enough for that service"
        }
      }
    })
  end

  defmodule BookingRejectedError do
    @moduledoc """
    Returned with HTTP 422 when the booking can never succeed as asked.

    **None of these are worth retrying** with the same arguments — unlike the
    409 conflicts. Either the service is unknown, no office can ever provide
    the capabilities, or the appointment has already been cancelled.
    """
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "BookingRejectedError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{
              type: :string,
              enum: [
                "unknown_service",
                "no_eligible_office",
                "appointment_cancelled",
                "validation_failed"
              ]
            },
            message: %Schema{type: :string}
          },
          required: [:code, :message]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "no_eligible_office",
          "message" => "No office provides the capabilities this service requires"
        }
      }
    })
  end

  defmodule NoEligibleOfficeError do
    @moduledoc "Returned when accept finds no office that provides the required capabilities AND has free capacity."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "NoEligibleOfficeError",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, enum: ["no_eligible_office"]},
            message: %Schema{type: :string}
          },
          required: [:code, :message]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "code" => "no_eligible_office",
          "message" => "No office both provides the required capabilities and has free capacity"
        }
      }
    })
  end

  defmodule Handoff do
    @moduledoc "An incoming-patient handoff record carried to the office that received the assignment."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Handoff",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        status: %Schema{type: :string, enum: ["pending", "acknowledged"]},
        patient_name: %Schema{
          type: :string,
          nullable: true,
          description: "Snapshotted at handoff time"
        },
        office_name: %Schema{
          type: :string,
          nullable: true,
          description: "Snapshotted at handoff time"
        },
        required_capabilities: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Capability names the patient requires, snapshotted as strings"
        },
        acknowledged_at: %Schema{type: :string, format: :"date-time", nullable: true},
        acknowledged_by: %Schema{type: :string, nullable: true},
        office_id: %Schema{type: :integer, nullable: true},
        patient_id: %Schema{type: :integer, nullable: true},
        queue_entry_id: %Schema{type: :integer, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status, :required_capabilities, :inserted_at, :updated_at]
    })
  end

  defmodule HandoffList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HandoffList",
      type: :array,
      items: SchedulingWeb.Schemas.Handoff
    })
  end

  defmodule HandoffAcknowledgeRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "HandoffAcknowledgeRequest",
      type: :object,
      properties: %{
        acknowledged_by: %Schema{
          type: :string,
          nullable: true,
          description: "User attribution stamped on the handoff"
        }
      }
    })
  end

  defmodule VisitEvent do
    @moduledoc "One row in the visit-lifecycle event log."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "VisitEvent",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        type: %Schema{
          type: :string,
          description:
            "Event type, e.g. visit.created, queue_entry.completed, handoff.acknowledged"
        },
        visit_id: %Schema{type: :integer, nullable: true},
        queue_entry_id: %Schema{type: :integer, nullable: true},
        patient_id: %Schema{type: :integer, nullable: true},
        handoff_id: %Schema{type: :integer, nullable: true},
        actor_type: %Schema{
          type: :string,
          nullable: true,
          description: "e.g. user, service, system"
        },
        actor_id: %Schema{
          type: :string,
          nullable: true,
          description: "Subject id within actor_type"
        },
        payload: %Schema{type: :object, description: "Event-specific extras"},
        occurred_at: %Schema{type: :string, format: :"date-time"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :type, :occurred_at, :inserted_at, :updated_at]
    })
  end

  defmodule VisitEventList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VisitEventList",
      type: :array,
      items: SchedulingWeb.Schemas.VisitEvent
    })
  end

  defmodule RoutingDecision do
    @moduledoc "An audit record of one matcher run during the accept flow."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "RoutingDecision",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        patient_name: %Schema{
          type: :string,
          nullable: true,
          description: "Snapshotted patient name"
        },
        chosen_office_name: %Schema{
          type: :string,
          nullable: true,
          description: "Snapshotted office name; nil when no office was eligible"
        },
        required_capabilities: %Schema{type: :array, items: %Schema{type: :string}},
        eligible_offices: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Names of offices that provided every required capability"
        },
        rationale: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable explanation of why this office was chosen (or none)"
        },
        accepted_by: %Schema{type: :string, nullable: true},
        patient_id: %Schema{type: :integer, nullable: true},
        chosen_office_id: %Schema{type: :integer, nullable: true},
        queue_entry_id: %Schema{type: :integer, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :required_capabilities, :eligible_offices, :inserted_at, :updated_at]
    })
  end

  defmodule RoutingDecisionList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RoutingDecisionList",
      type: :array,
      items: SchedulingWeb.Schemas.RoutingDecision
    })
  end

  defmodule OfficeWithLoad do
    @moduledoc "An office plus its current load (count of active queue entries)."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "OfficeWithLoad",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string},
        intake_capacity: %Schema{type: :integer},
        capabilities: %Schema{type: :array, items: SchedulingWeb.Schemas.Capability},
        load: %Schema{
          type: :integer,
          description: "Count of active queue entries currently consuming this office's capacity"
        },
        free: %Schema{type: :integer, description: "intake_capacity - load (never negative)"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :name,
        :intake_capacity,
        :capabilities,
        :load,
        :free,
        :inserted_at,
        :updated_at
      ]
    })
  end

  defmodule BoardSnapshot do
    @moduledoc "Single-shot snapshot of the live board: queue + capacity + pending handoffs."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "BoardSnapshot",
      type: :object,
      properties: %{
        waiting: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.QueueEntry,
          description: "Waiting queue, highest priority first"
        },
        active: %Schema{
          type: :array,
          items: SchedulingWeb.Schemas.QueueEntry,
          description: "Entries currently consuming office capacity"
        },
        offices: %Schema{type: :array, items: SchedulingWeb.Schemas.OfficeWithLoad},
        pending_handoffs: %Schema{type: :array, items: SchedulingWeb.Schemas.Handoff},
        generated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:waiting, :active, :offices, :pending_handoffs, :generated_at]
    })
  end

  defmodule WebhookSubscription do
    @moduledoc "An outbound webhook subscription."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "WebhookSubscription",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        url: %Schema{type: :string, description: "HTTPS URL receiving signed POSTs"},
        event_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Event types to receive (empty = all). e.g. [\"visit.created\", \"queue_entry.completed\"]"
        },
        active: %Schema{type: :boolean},
        description: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :url, :event_types, :active, :inserted_at, :updated_at]
    })
  end

  defmodule WebhookSubscriptionCreated do
    @moduledoc "Response on create — includes the generated secret. Only returned once."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "WebhookSubscriptionCreated",
      allOf: [
        SchedulingWeb.Schemas.WebhookSubscription,
        %Schema{
          type: :object,
          properties: %{
            secret: %Schema{
              type: :string,
              description:
                "HMAC key used to sign delivery bodies. STORED ONLY ONCE — copy now; subsequent GETs do not include it. Rotation = new subscription."
            }
          },
          required: [:secret]
        }
      ]
    })
  end

  defmodule WebhookSubscriptionList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookSubscriptionList",
      type: :array,
      items: SchedulingWeb.Schemas.WebhookSubscription
    })
  end

  defmodule WebhookSubscriptionRequest do
    @moduledoc "Request body for creating or updating a webhook subscription."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "WebhookSubscriptionRequest",
      type: :object,
      properties: %{
        webhook_subscription: %Schema{
          type: :object,
          properties: %{
            url: %Schema{type: :string, description: "HTTPS URL to deliver to"},
            event_types: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Event types to receive; pass [] (default) for all"
            },
            active: %Schema{type: :boolean, description: "Default true"},
            description: %Schema{type: :string, nullable: true},
            secret: %Schema{
              type: :string,
              nullable: true,
              description:
                "16–256 chars. If omitted on create, a random one is generated. Do not update once subscription is in use."
            }
          },
          required: [:url]
        }
      },
      required: [:webhook_subscription]
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
