defmodule SchedulingWeb.Api.AppointmentController do
  @moduledoc """
  JSON API for booking: create, list, show, reschedule and cancel appointments,
  plus a slot search for finding when a room is free.

  ## The response deliberately cannot say why a patient is here

  An appointment carries its resolved `required_capabilities` — equipment — and
  no service or diagnosis field. The service code is expanded at booking and
  discarded, so there is nothing to serialize even if a caller wanted it. See
  `docs/data-boundary.md`; the serializer must never reintroduce it by looking
  one up.

  ## Retry or don't

  The error mapping is built around the one distinction a client actually
  needs to act on:

    * **409** — the time was not available. `slots_taken` (a concurrent
      booking won the race) and `no_available_slots` (nothing free in the
      window). Both worth retrying, the first immediately.
    * **422** — the request can never succeed as asked. `unknown_service`,
      `no_eligible_office`, `appointment_cancelled`. Retrying is pointless.

  A client that retries a 422 forever is a client we misled, so each operation
  says which of its failures are worth another attempt.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Booking
  alias Scheduling.Booking.Appointment
  alias SchedulingWeb.ErrorEnvelope
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["booking"])

  # --- list -------------------------------------------------------------------

  operation(:index,
    summary: "List appointments",
    description:
      "Soonest first. Filters compose:\n\n" <>
        "- `?patient_id=<int>` — one patient's appointments\n" <>
        "- `?status=<booked|arrived|completed|cancelled>` — repeatable\n\n" <>
        "Cancelled appointments are included unless filtered out; a cancelled " <>
        "appointment is the explanation for a slot that was once taken.",
    parameters: [
      patient_id: [in: :query, type: :integer, required: false],
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "`booked`, `arrived`, `completed` or `cancelled`"
      ]
    ],
    responses: [
      ok: {"Appointments", "application/json", Schemas.AppointmentList}
    ]
  )

  def index(conn, params) do
    opts =
      []
      |> put_opt(:patient_id, parse_int(params["patient_id"]))
      |> put_opt(:status, parse_status(params["status"]))

    json(conn, Enum.map(Booking.list_appointments(opts), &serialize/1))
  end

  # --- show -------------------------------------------------------------------

  operation(:show,
    summary: "Get an appointment",
    parameters: [id: [in: :path, description: "Appointment id", type: :integer]],
    responses: [
      ok: {"Appointment", "application/json", Schemas.Appointment},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, appointment} <- fetch(id) do
      json(conn, serialize(appointment))
    end
  end

  # --- create -----------------------------------------------------------------

  operation(:create,
    summary: "Book an appointment",
    description:
      "Resolves the service to its required capabilities, finds the offices " <>
        "that can provide them, derives the `binding`, and reserves the " <>
        "earliest run of consecutive open slots long enough for the service.\n\n" <>
        "Supply `service_code` (preferred — a stable, possibly opaque contract " <>
        "key) or `required_capability_ids`. `diagnosis_id` is deliberately not " <>
        "accepted here: a row id is an implementation detail, and a readable " <>
        "clinical label alongside a patient id is health data.\n\n" <>
        "Failure modes — **the 409s are worth retrying, the 422s are not**:\n" <>
        "  * 409 `slots_taken` — a concurrent booking took the slots between " <>
        "our search and our write. Retry immediately; it may well succeed.\n" <>
        "  * 409 `no_available_slots` — no long-enough run of open slots at or " <>
        "after `from`. Retry with a different `from`.\n" <>
        "  * 422 `no_eligible_office` — no office provides these capabilities " <>
        "at all. Retrying cannot help; the catalog or the rooms must change.\n" <>
        "  * 422 `unknown_service` — no routing template with that code.\n\n" <>
        "Pass `external_ref` to make the call idempotent: booking again with " <>
        "the same value returns the original appointment rather than a second " <>
        "one, so a request whose response you never saw is safe to repeat.",
    request_body:
      {"Booking attrs", "application/json", Schemas.AppointmentCreateRequest, required: true},
    responses: [
      created: {"Booked", "application/json", Schemas.Appointment},
      conflict:
        {"Time unavailable — retryable", "application/json", Schemas.BookingConflictError},
      unprocessable_entity:
        {"Cannot be booked as asked", "application/json", Schemas.BookingRejectedError}
    ]
  )

  def create(conn, params) do
    attrs = Map.get(params, "appointment", %{})

    case Booking.book(book_attrs(attrs)) do
      {:ok, appointment} ->
        conn
        |> put_status(:created)
        |> json(serialize(appointment))

      {:error, reason} ->
        render_booking_error(conn, reason)
    end
  end

  # --- reschedule -------------------------------------------------------------

  operation(:update,
    summary: "Reschedule an appointment",
    description:
      "Moves the appointment to a new run of slots at or after `from`, " <>
        "releasing the old ones.\n\n" <>
        "It keeps its capabilities and its length — the run it currently holds " <>
        "is what defines how long it is — and its `binding` is **re-derived**, " <>
        "because the set of offices able to serve it may have changed since it " <>
        "was booked. An appointment can move to a time overlapping its current " <>
        "one; its own slots are released before the search.\n\n" <>
        "If no new run is found the appointment keeps the slots it had. " <>
        "409s are worth retrying; 422s are not.",
    parameters: [id: [in: :path, description: "Appointment id", type: :integer]],
    request_body:
      {"Reschedule attrs", "application/json", Schemas.AppointmentRescheduleRequest,
       required: false},
    responses: [
      ok: {"Rescheduled", "application/json", Schemas.Appointment},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      conflict:
        {"No new time available — retryable", "application/json", Schemas.BookingConflictError},
      unprocessable_entity:
        {"Cannot be rescheduled", "application/json", Schemas.BookingRejectedError}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "appointment", %{})

    with {:ok, appointment} <- fetch(id) do
      opts =
        case parse_datetime(attrs["from"]) do
          nil -> []
          from -> [from: from]
        end

      case Booking.reschedule_appointment(appointment, opts) do
        {:ok, moved} -> json(conn, serialize(moved))
        {:error, reason} -> render_booking_error(conn, reason)
      end
    end
  end

  # --- cancel -----------------------------------------------------------------

  operation(:cancel,
    summary: "Cancel an appointment",
    description:
      "Releases the appointment's slots back to `open` and marks it " <>
        "`cancelled`. Idempotent: cancelling an already-cancelled appointment " <>
        "succeeds and releases nothing, so a retry is always safe.",
    parameters: [id: [in: :path, description: "Appointment id", type: :integer]],
    responses: [
      ok: {"Cancelled", "application/json", Schemas.Appointment},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def cancel(conn, %{"id" => id}) do
    with {:ok, appointment} <- fetch(id),
         {:ok, cancelled} <- Booking.cancel_appointment(appointment) do
      json(conn, serialize(cancelled))
    end
  end

  # --- slots ------------------------------------------------------------------

  operation(:slots,
    summary: "Search bookable slots",
    description:
      "Lists slots in start order, for finding when a room is free before " <>
        "booking. Filters:\n\n" <>
        "- `?office_id=<int>`\n" <>
        "- `?status=<open|blocked|booked>`\n" <>
        "- `?from=<iso8601>` — inclusive lower bound on `starts_at`\n" <>
        "- `?to=<iso8601>` — exclusive upper bound on `starts_at`\n\n" <>
        "Note a slot being `open` is not a reservation. Two clients can both " <>
        "see the same open slot; only one will win the booking, and the other " <>
        "gets `409 slots_taken`.",
    parameters: [
      office_id: [in: :query, type: :integer, required: false],
      status: [in: :query, type: :string, required: false],
      from: [in: :query, type: :string, required: false, description: "ISO 8601"],
      to: [in: :query, type: :string, required: false, description: "ISO 8601"]
    ],
    responses: [
      ok: {"Slots", "application/json", Schemas.SlotList}
    ]
  )

  def slots(conn, params) do
    opts =
      []
      |> put_opt(:office_id, parse_int(params["office_id"]))
      |> put_opt(:status, parse_slot_status(params["status"]))
      |> put_opt(:from, parse_datetime(params["from"]))
      |> put_opt(:to, parse_datetime(params["to"]))

    json(conn, Enum.map(Booking.list_slots(opts), &serialize_slot/1))
  end

  # --- error mapping ----------------------------------------------------------

  # The split is retry-or-don't, not a severity ranking. See the moduledoc.
  defp render_booking_error(conn, :slots_taken) do
    conflict(
      conn,
      "slots_taken",
      "Another booking took those slots first. This is safe to retry immediately."
    )
  end

  defp render_booking_error(conn, :no_available_slots) do
    conflict(
      conn,
      "no_available_slots",
      "No run of consecutive open slots long enough for that service at or after the requested time"
    )
  end

  defp render_booking_error(conn, :no_eligible_office) do
    rejected(
      conn,
      "no_eligible_office",
      "No office provides the capabilities this service requires. Retrying will not help."
    )
  end

  defp render_booking_error(conn, :unknown_service) do
    rejected(conn, "unknown_service", "No routing template exists with that service code")
  end

  defp render_booking_error(conn, :appointment_cancelled) do
    rejected(conn, "appointment_cancelled", "A cancelled appointment cannot be rescheduled")
  end

  defp render_booking_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.changeset_envelope(changeset))
  end

  defp render_booking_error(conn, reason) do
    rejected(conn, "booking_failed", "The booking could not be completed: #{inspect(reason)}")
  end

  defp conflict(conn, code, message) do
    conn
    |> put_status(:conflict)
    |> json(ErrorEnvelope.error_envelope(code, message))
  end

  defp rejected(conn, code, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.error_envelope(code, message))
  end

  # --- params -----------------------------------------------------------------

  defp book_attrs(attrs) do
    %{
      patient_id: attrs["patient_id"],
      service_code: attrs["service_code"],
      required_capability_ids: attrs["required_capability_ids"],
      from: parse_datetime(attrs["from"]),
      external_ref: attrs["external_ref"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  # An unrecognised status is dropped rather than erroring: it narrows to
  # nothing otherwise, and a silently-empty list is worse than ignoring it.
  defp parse_status(value), do: parse_enum(value, ~w(booked arrived completed cancelled))

  defp parse_slot_status(value), do: parse_enum(value, ~w(open blocked booked))

  defp parse_enum(value, allowed) when is_binary(value) do
    if value in allowed, do: String.to_existing_atom(value), else: nil
  end

  defp parse_enum(_value, _allowed), do: nil

  # --- fetch / serialize ------------------------------------------------------

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Booking.get_appointment!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # No service, no diagnosis, no clinical label — there is nothing stored to
  # serialize, and nothing here looks one up. `docs/data-boundary.md`.
  defp serialize(appointment) do
    %{
      id: appointment.id,
      status: appointment.status,
      binding: appointment.binding,
      patient_id: appointment.patient_id,
      external_ref: appointment.external_ref,
      office_id: Appointment.office_id(appointment),
      starts_at: Appointment.starts_at(appointment),
      ends_at: Appointment.ends_at(appointment),
      required_capabilities: serialize_capabilities(appointment.required_capabilities),
      inserted_at: appointment.inserted_at,
      updated_at: appointment.updated_at
    }
  end

  defp serialize_slot(slot) do
    %{
      id: slot.id,
      office_id: slot.office_id,
      availability_rule_id: slot.availability_rule_id,
      appointment_id: slot.appointment_id,
      starts_at: slot.starts_at,
      ends_at: slot.ends_at,
      status: slot.status,
      inserted_at: slot.inserted_at,
      updated_at: slot.updated_at
    }
  end

  defp serialize_capabilities(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_capabilities(caps) when is_list(caps) do
    Enum.map(caps, fn c ->
      %{
        id: c.id,
        name: c.name,
        description: c.description,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      }
    end)
  end
end
