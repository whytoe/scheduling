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
        required_form_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Intake form types that must be completed (status=completed AND not flagged) before a patient with this diagnosis can be assigned to an office."
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
            code: %Schema{type: :string, nullable: true, description: "Optional unique short code"},
            capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description: "Capability ids that become this diagnosis's default required capabilities. Omit to leave existing associations unchanged; pass [] to clear them."
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
      example: %{"diagnosis" => %{"name" => "Stroke Workup", "code" => "DX-STRK", "capability_ids" => [1, 2], "required_form_types" => ["stroke-consent"]}}
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
        client_id: %Schema{type: :string, format: :uuid, description: "Canonical scheduling-owned UUID. Auto-generated if not supplied. Used as the inter-service reference; not the EMR record id."},
        external_id: %Schema{type: :string, nullable: true, description: "Optional id assigned by the upstream check-in / queueing app"},
        intake_patient_id: %Schema{type: :string, format: :uuid, nullable: true, description: "UUID this patient has in the intake-form system. Used at accept time to look up their completed forms."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :client_id, :inserted_at, :updated_at],
      example: %{
        "id" => 1,
        "name" => "Jane Doe",
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
            client_id: %Schema{type: :string, format: :uuid, nullable: true, description: "Canonical UUID. Optional on create: server generates one if omitted."},
            external_id: %Schema{type: :string, nullable: true, description: "Optional unique check-in id"},
            intake_patient_id: %Schema{type: :string, format: :uuid, nullable: true, description: "Optional unique intake-form-system UUID"}
          },
          required: [:name]
        }
      },
      required: [:patient],
      example: %{"patient" => %{"name" => "Jane Doe", "external_id" => "checkin-7a3f", "intake_patient_id" => "5e1f2c8a-1d3b-4ee9-9a64-8e3b6cf21e10"}}
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
            started_at: %Schema{type: :string, format: :"date-time", description: "Defaults to now if omitted"}
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
          description: "Lifecycle status; entries in `assigned` and `in_service` consume office capacity"
        },
        priority: %Schema{type: :integer, minimum: 0, description: "Higher = served sooner"},
        patient: %Schema{nullable: true, allOf: [SchedulingWeb.Schemas.Patient]},
        patient_id: %Schema{type: :integer},
        diagnosis_id: %Schema{type: :integer, nullable: true},
        assigned_office_id: %Schema{type: :integer, nullable: true},
        visit_id: %Schema{type: :integer, nullable: true, description: "Parent Visit this entry belongs to (set when created via the queueing service's sign-in flow)"},
        required_capabilities: %Schema{type: :array, items: SchedulingWeb.Schemas.Capability},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status, :priority, :patient_id, :required_capabilities, :inserted_at, :updated_at]
    })
  end

  defmodule QueueEntryList do
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "QueueEntryList", type: :array, items: SchedulingWeb.Schemas.QueueEntry})
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
            diagnosis_id: %Schema{type: :integer, nullable: true, description: "Optional diagnosis"},
            visit_id: %Schema{type: :integer, nullable: true, description: "Parent Visit. Set by the queueing service's sign-in flow."},
            priority: %Schema{type: :integer, minimum: 0, description: "Defaults to 0"},
            required_capability_ids: %Schema{
              type: :array,
              items: %Schema{type: :integer},
              description: "Capability ids this patient requires. Set explicitly; the diagnosis default isn't auto-applied yet."
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
        accepted_by: %Schema{type: :string, nullable: true, description: "User attribution recorded in the routing decision audit log"}
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
          description: "Capabilities the new service requires. Omit to keep the current set; pass [] to clear."
        }
      }
    })
  end

  defmodule ComplianceFailedError do
    @moduledoc "Returned when the patient hasn't completed every required intake form."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ComplianceFailedError",
      type: :object,
      properties: %{
        error: %Schema{type: :string, enum: ["compliance_failed"]},
        missing_form_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Form types the patient is missing a completed-and-not-flagged response for"
        }
      },
      required: [:error, :missing_form_types],
      example: %{"error" => "compliance_failed", "missing_form_types" => ["stroke-consent"]}
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
        error: %Schema{type: :string, enum: ["compliance_unavailable"]},
        reason: %Schema{type: :string, description: "Inspect of the underlying transport error"}
      },
      required: [:error],
      example: %{"error" => "compliance_unavailable", "reason" => "{:http_status, 401, %{...}}"}
    })
  end

  defmodule NoEligibleOfficeError do
    @moduledoc "Returned when accept finds no office that provides the required capabilities AND has free capacity."
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "NoEligibleOfficeError",
      type: :object,
      properties: %{error: %Schema{type: :string, enum: ["no_eligible_office"]}},
      required: [:error],
      example: %{"error" => "no_eligible_office"}
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
        patient_name: %Schema{type: :string, nullable: true, description: "Snapshotted at handoff time"},
        office_name: %Schema{type: :string, nullable: true, description: "Snapshotted at handoff time"},
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
    OpenApiSpex.schema(%{title: "HandoffList", type: :array, items: SchedulingWeb.Schemas.Handoff})
  end

  defmodule HandoffAcknowledgeRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "HandoffAcknowledgeRequest",
      type: :object,
      properties: %{
        acknowledged_by: %Schema{type: :string, nullable: true, description: "User attribution stamped on the handoff"}
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
        type: %Schema{type: :string, description: "Event type, e.g. visit.created, queue_entry.completed, handoff.acknowledged"},
        visit_id: %Schema{type: :integer, nullable: true},
        queue_entry_id: %Schema{type: :integer, nullable: true},
        patient_id: %Schema{type: :integer, nullable: true},
        handoff_id: %Schema{type: :integer, nullable: true},
        actor_type: %Schema{type: :string, nullable: true, description: "e.g. user, service, system"},
        actor_id: %Schema{type: :string, nullable: true, description: "Subject id within actor_type"},
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
    OpenApiSpex.schema(%{title: "VisitEventList", type: :array, items: SchedulingWeb.Schemas.VisitEvent})
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
        patient_name: %Schema{type: :string, nullable: true, description: "Snapshotted patient name"},
        chosen_office_name: %Schema{type: :string, nullable: true, description: "Snapshotted office name; nil when no office was eligible"},
        required_capabilities: %Schema{type: :array, items: %Schema{type: :string}},
        eligible_offices: %Schema{type: :array, items: %Schema{type: :string}, description: "Names of offices that provided every required capability"},
        rationale: %Schema{type: :string, nullable: true, description: "Human-readable explanation of why this office was chosen (or none)"},
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
    OpenApiSpex.schema(%{title: "RoutingDecisionList", type: :array, items: SchedulingWeb.Schemas.RoutingDecision})
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
        load: %Schema{type: :integer, description: "Count of active queue entries currently consuming this office's capacity"},
        free: %Schema{type: :integer, description: "intake_capacity - load (never negative)"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :intake_capacity, :capabilities, :load, :free, :inserted_at, :updated_at]
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
        waiting: %Schema{type: :array, items: SchedulingWeb.Schemas.QueueEntry, description: "Waiting queue, highest priority first"},
        active: %Schema{type: :array, items: SchedulingWeb.Schemas.QueueEntry, description: "Entries currently consuming office capacity"},
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
          description: "Event types to receive (empty = all). e.g. [\"visit.created\", \"queue_entry.completed\"]"
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
              description: "HMAC key used to sign delivery bodies. STORED ONLY ONCE — copy now; subsequent GETs do not include it. Rotation = new subscription."
            }
          },
          required: [:secret]
        }
      ]
    })
  end

  defmodule WebhookSubscriptionList do
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "WebhookSubscriptionList", type: :array, items: SchedulingWeb.Schemas.WebhookSubscription})
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
              description: "16–256 chars. If omitted on create, a random one is generated. Do not update once subscription is in use."
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
