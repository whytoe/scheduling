defmodule SchedulingWeb.AppointmentLive.Index do
  @moduledoc """
  The operator's booking surface: what is booked, and the flow for booking it.

  Sits in the operator `live_session` beside `/board` and `/queue` rather than
  with the catalog screens — booking a patient is shift work, not
  administration. `/availability`, which defines what is bookable at all, is
  the admin counterpart.

  ## Three things this screen has to get right

  **Offer times that exist.** The booking flow asks
  `Scheduling.Booking.available_starts/2` for real candidates rather than
  presenting a datetime field. A free-text time is an invitation to pick one
  the calendar cannot honour, and the refusal arrives after the operator has
  already told the patient.

  **Say what `binding` means, not the word.** "Provisional" reads as
  *unconfirmed* to anyone who has used a booking system before, and it means
  nothing of the sort — the appointment is firm, it is the *room* that is not
  fixed. Committed means one room could serve it, so that room is settled. Both
  are shown with their consequence rather than their label.

  **Never name the service.** An appointment stores the capabilities it needs,
  never the service that implied them (`docs/data-boundary.md`). Choosing a
  service while booking is fine — it is expanded and discarded. Displaying one
  afterwards would mean looking it up, which is the leak the design exists to
  prevent. Rows show equipment.

  ## Booking can fail on a time this screen just displayed

  `available_starts/2` is a preview, not a hold: another operator can take a
  listed slot in the seconds before this one clicks. That is an ordinary
  outcome, not an error state — the flash says so plainly and the candidate
  list refreshes so the next attempt is against current reality.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Booking
  alias Scheduling.Booking.Appointment
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients

  @statuses ~w(booked arrived completed cancelled)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Appointments")
     |> assign(:status_filter, "booked")
     |> assign(:statuses, @statuses)
     |> assign(:confirm, nil)
     |> assign(:booking, nil)
     |> assign(:candidates, nil)
     |> assign(:patients, Patients.list_patients())
     |> assign(:services, Catalog.list_diagnoses())
     |> load_offices()
     |> load_appointments()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, :booking, nil)

  defp apply_action(socket, :new, _params) do
    assign(socket, :booking, %{patient_id: nil, service_code: nil, from: today_iso()})
  end

  # --- booking flow ----------------------------------------------------------

  @impl true
  def handle_event("booking_change", %{"booking" => params}, socket) do
    booking = %{
      patient_id: blank_to_nil(params["patient_id"]),
      service_code: blank_to_nil(params["service_code"]),
      from: params["from"] || today_iso()
    }

    {:noreply, socket |> assign(:booking, booking) |> refresh_candidates()}
  end

  def handle_event("book", %{"starts_at" => starts_at}, socket) do
    booking = socket.assigns.booking

    attrs = %{
      patient_id: booking.patient_id,
      service_code: booking.service_code,
      from: parse_datetime(starts_at)
    }

    case Booking.book(attrs) do
      {:ok, appointment} ->
        {:noreply,
         socket
         |> put_flash(:info, booked_message(appointment))
         |> assign(:booking, nil)
         |> load_appointments()
         |> push_patch(to: ~p"/appointments")}

      {:error, :no_available_slots} ->
        # Someone took it between the preview and the click. Ordinary, not an
        # error state — refresh so the next attempt sees current reality.
        {:noreply,
         socket
         |> put_flash(
           :error,
           "That time was taken while you were choosing. The list below is now up to date."
         )
         |> refresh_candidates()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, booking_error_message(reason))}
    end
  end

  # --- arrive ----------------------------------------------------------------

  def handle_event("arrive", %{"id" => id}, socket) do
    appointment = Booking.get_appointment!(id)

    case Booking.arrive(appointment, actor_opts(socket)) do
      {:ok, %{entry: entry}} ->
        {:noreply,
         socket
         |> put_flash(:info, arrived_message(entry))
         |> load_appointments()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not check that patient in: #{reason}.")}
    end
  end

  # --- reschedule ------------------------------------------------------------

  # `appointment_id` rather than `id`: an input named "id" overrides the form
  # element's own ID, which LiveView warns about.
  def handle_event("reschedule", %{"appointment_id" => id, "from" => from}, socket) do
    appointment = Booking.get_appointment!(id)

    case Booking.reschedule_appointment(appointment, from: parse_date_start(from)) do
      {:ok, moved} ->
        {:noreply,
         socket
         |> put_flash(:info, "Moved to #{when_label(moved)}.")
         |> load_appointments()}

      {:error, :no_available_slots} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Nothing long enough is free from then on. The appointment is unchanged."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, booking_error_message(reason))}
    end
  end

  # --- cancel ----------------------------------------------------------------

  def handle_event("confirm_cancel", %{"id" => id}, socket) do
    appointment = Booking.get_appointment!(id)

    {:noreply,
     assign(socket, :confirm, %{
       id: appointment.id,
       patient: patient_label(appointment),
       when: when_label(appointment),
       slots: length(appointment.slots)
     })}
  end

  def handle_event("dismiss_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("cancel_appointment", %{"id" => id}, socket) do
    appointment = Booking.get_appointment!(id)

    case Booking.cancel_appointment(appointment) do
      {:ok, _cancelled} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:info, "Cancelled. Its time is free for someone else.")
         |> load_appointments()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not cancel that appointment.")}
    end
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> load_appointments()}
  end

  # --- loading ---------------------------------------------------------------

  defp load_appointments(socket) do
    status = socket.assigns.status_filter

    opts = if status in ["", "all"], do: [], else: [status: String.to_existing_atom(status)]

    assign(socket, :appointments, Booking.list_appointments(opts))
  end

  # Appointments preload their slots but not the slots' office, and the office
  # is only needed for a name. One lookup keyed by id beats N preloads, and
  # avoids widening the context function for a display concern.
  defp load_offices(socket) do
    assign(socket, :offices_by_id, Map.new(Offices.list_offices(), &{&1.id, &1}))
  end

  defp refresh_candidates(socket) do
    booking = socket.assigns.booking

    cond do
      is_nil(booking) ->
        assign(socket, :candidates, nil)

      is_nil(booking.patient_id) or is_nil(booking.service_code) ->
        assign(socket, :candidates, nil)

      true ->
        from = parse_date_start(booking.from)

        case Booking.available_starts(%{service_code: booking.service_code},
               from: from,
               to: DateTime.add(from, 14 * 24 * 3600, :second),
               limit: 40
             ) do
          {:ok, starts} -> assign(socket, :candidates, {:ok, starts})
          {:error, reason} -> assign(socket, :candidates, {:error, reason})
        end
    end
  end

  # --- labels ----------------------------------------------------------------

  defp patient_label(%{patient: %{name: name}}) when is_binary(name), do: name
  defp patient_label(appointment), do: "patient ##{appointment.patient_id}"

  defp when_label(appointment) do
    case Appointment.starts_at(appointment) do
      nil -> "no time held"
      starts_at -> format_utc(starts_at)
    end
  end

  # Always marked UTC. An operator misreading a booking time is precisely the
  # failure this screen exists to prevent, and an unlabelled timestamp invites
  # it.
  defp format_utc(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b %Y, %H:%M UTC")

  defp office_for(appointment, offices_by_id) do
    case Appointment.office_id(appointment) do
      nil -> nil
      id -> Map.get(offices_by_id, id)
    end
  end

  # Only a *committed* appointment has a room to name. A provisional one holds
  # slots in some office, but the matcher may send the patient elsewhere on
  # arrival — so that office is where the **time** is reserved, not where the
  # patient will go, and the two differ precisely when binding is provisional.
  #
  # Naming it would invite someone to walk the patient to a room they may not
  # be going to. The held office is capacity information, useful to whoever
  # manages the calendar and misleading to whoever greets the patient, so this
  # screen does not show it.
  defp office_label(%{binding: :provisional}, _offices_by_id), do: "Decided on arrival"

  defp office_label(appointment, offices_by_id) do
    case office_for(appointment, offices_by_id) do
      nil -> "—"
      office -> office.name
    end
  end

  defp capability_names(appointment) do
    appointment.required_capabilities |> Enum.map(& &1.name) |> Enum.sort()
  end

  # Appointment statuses now live in the shared badge vocabulary
  # (`SchedulingWeb.CoreComponents`), so the badges need no mapping or label
  # override here — `booked`, `arrived`, `cancelled` and `completed` render
  # themselves.
  #
  # The filter tabs still need this: they include "all", which is not a status
  # and has no badge.
  defp status_label(status), do: status |> to_string() |> String.capitalize()

  defp booked_message(appointment) do
    "Booked for #{when_label(appointment)}. " <> binding_sentence(appointment.binding)
  end

  defp binding_sentence(:committed),
    do: "Only one room can provide this, so it is fixed to that room."

  defp binding_sentence(:provisional),
    do: "Several rooms can provide this; the room is chosen when the patient arrives."

  defp arrived_message(%{status: :assigned} = entry) do
    "Checked in and sent straight through — room assigned, staff notified. " <>
      "Entry ##{entry.id}."
  end

  defp arrived_message(entry) do
    "Checked in and added to the queue. The board will route them. Entry ##{entry.id}."
  end

  defp booking_error_message(:no_eligible_office),
    do: "No room provides what that service needs. Add the capability to an office first."

  defp booking_error_message(:unknown_service), do: "That service no longer exists."

  defp booking_error_message(:no_service_specified), do: "Choose a service first."

  defp booking_error_message(:appointment_cancelled),
    do: "That appointment is cancelled and cannot be moved."

  defp booking_error_message(:slots_taken),
    do: "Someone booked that time first. Try another."

  defp booking_error_message(%Ecto.Changeset{}), do: "Those details are not valid."

  defp booking_error_message(other), do: "The booking could not be completed (#{inspect(other)})."

  defp actor_opts(socket) do
    Scheduling.Auth.Scope.actor_opts(socket.assigns[:current_scope])
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp today_iso, do: Date.utc_today() |> Date.to_iso8601()

  defp parse_date_start(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  defp parse_date_start(_), do: DateTime.utc_now()

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp cancellable?(%{status: status}), do: status in [:booked]
  defp arrivable?(%{status: status}), do: status == :booked

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:appointments} wide>
      <.page_head title="Appointments">
        <:subtitle>
          Booked patients, and the flow for booking them. Times are shown in UTC.
        </:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/appointments/new"}>
            <.icon name="hero-plus" class="size-4" />Book
          </.button>
        </:actions>
      </.page_head>

      <.booking_panel
        :if={@live_action == :new}
        booking={@booking}
        patients={@patients}
        services={@services}
        candidates={@candidates}
        offices_by_id={@offices_by_id}
      />

      <div class="tabs" role="tablist" aria-label="Filter by status">
        <button
          :for={status <- @statuses ++ ["all"]}
          type="button"
          role="tab"
          aria-selected={@status_filter == status}
          class={["tab", @status_filter == status && "tab--active"]}
          phx-click={JS.push("filter", value: %{status: status})}
        >
          {status_label(status)}
        </button>
      </div>

      <.empty_state
        :if={@appointments == []}
        icon="hero-calendar-days"
        title="Nothing here"
      >
        No appointments with that status. Booking one needs an office with availability —
        see the Availability screen.
      </.empty_state>

      <table :if={@appointments != []} class="table" style="margin-top:var(--s-4)">
        <thead>
          <tr>
            <th>Patient</th>
            <th style="width:230px">When (UTC)</th>
            <th style="width:150px">Room</th>
            <th>Needs</th>
            <th style="width:150px">Status</th>
            <th style="width:1px"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={appointment <- @appointments} id={"appointment-#{appointment.id}"}>
            <td class="font-semibold">{patient_label(appointment)}</td>
            <td class="tnum">{when_label(appointment)}</td>
            <td>
              <span>{office_label(appointment, @offices_by_id)}</span>
              <div class="t-small" style="color:var(--color-base-content-muted)">
                {binding_hint(appointment.binding)}
              </div>
            </td>
            <td><.cap_row caps={capability_names(appointment)} /></td>
            <td>
              <.status_badge status={to_string(appointment.status)} />
            </td>
            <td>
              <form
                :if={cancellable?(appointment)}
                phx-submit="reschedule"
                style="display:flex;gap:var(--s-2);align-items:center;margin-bottom:var(--s-2)"
              >
                <input type="hidden" name="appointment_id" value={appointment.id} />
                <input
                  type="date"
                  name="from"
                  value={Date.utc_today() |> Date.to_iso8601()}
                  class="input tnum"
                  style="width:150px"
                  aria-label={"Move #{patient_label(appointment)} to on or after"}
                />
                <button type="submit" class="btn btn-ghost btn-sm">
                  <.icon name="hero-arrow-path" class="size-[15px]" />Move
                </button>
              </form>
              <div class="table__actions">
                <button
                  :if={arrivable?(appointment)}
                  type="button"
                  class="btn btn-primary btn-sm"
                  phx-click={JS.push("arrive", value: %{id: appointment.id})}
                >
                  <.icon name="hero-check-circle" class="size-[15px]" />Arrived
                </button>
                <button
                  :if={cancellable?(appointment)}
                  type="button"
                  class="btn btn-danger btn-sm"
                  aria-label={"Cancel #{patient_label(appointment)}'s appointment"}
                  phx-click={JS.push("confirm_cancel", value: %{id: appointment.id})}
                >
                  <.icon name="hero-x-mark" class="size-[15px]" />
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <.confirm_dialog
        id="cancel-appointment"
        show={@confirm != nil}
        tone="error"
        icon="hero-x-mark"
        title="Cancel this appointment?"
        confirm_label="Cancel appointment"
        on_confirm={@confirm && JS.push("cancel_appointment", value: %{id: @confirm.id})}
        on_cancel={JS.push("dismiss_cancel")}
      >
        <span :if={@confirm}>
          <b>{@confirm.patient}</b>'s appointment on {@confirm.when} will be cancelled, and the {@confirm.slots} slot(s) it holds released for someone else to book.
          <br />This system does not notify the patient.
        </span>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  # Says *why* the cell above reads as it does, rather than repeating it.
  # "Provisional" is the word an operator most reliably misreads — it sounds
  # like the booking is unconfirmed, when what is unfixed is only the room.
  defp binding_hint(:committed), do: "Only this room can provide it"
  defp binding_hint(:provisional), do: "Several rooms can — the matcher picks"
  defp binding_hint(_), do: ""

  attr :booking, :map, required: true
  attr :patients, :list, required: true
  attr :services, :list, required: true
  attr :candidates, :any, required: true
  attr :offices_by_id, :map, required: true

  defp booking_panel(assigns) do
    ~H"""
    <div class="editform">
      <div class="editform__title">
        <.icon name="hero-calendar-days" class="size-[18px]" />Book an appointment
      </div>

      <form phx-change="booking_change">
        <div class="cols cols--3" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="booking_patient_id">Patient</label>
            <select id="booking_patient_id" name="booking[patient_id]" class="input">
              <option value="">Choose a patient…</option>
              <option
                :for={patient <- @patients}
                value={patient.id}
                selected={to_string(@booking.patient_id) == to_string(patient.id)}
              >
                {patient.name}
              </option>
            </select>
          </div>

          <div class="field">
            <label class="field__label" for="booking_service_code">Service</label>
            <select id="booking_service_code" name="booking[service_code]" class="input">
              <option value="">Choose a service…</option>
              <option
                :for={service <- @services}
                value={service.code}
                selected={@booking.service_code == service.code}
              >
                {service.name} ({service.duration_minutes} min)
              </option>
            </select>
            <div class="field__hint">
              Decides how long is held and what equipment is needed. Not stored on the appointment.
            </div>
          </div>

          <div class="field">
            <label class="field__label" for="booking_from">Earliest date</label>
            <input
              type="date"
              id="booking_from"
              name="booking[from]"
              value={@booking.from}
              class="input tnum"
            />
          </div>
        </div>
      </form>

      <.candidate_list candidates={@candidates} offices_by_id={@offices_by_id} />
    </div>
    """
  end

  attr :candidates, :any, required: true
  attr :offices_by_id, :map, required: true

  defp candidate_list(assigns) do
    ~H"""
    <div :if={is_nil(@candidates)} class="t-small" style="margin-top:var(--s-4)">
      Choose a patient and a service to see available times.
    </div>

    <.callout
      :if={match?({:error, _}, @candidates)}
      tone="attention"
      icon="hero-exclamation-triangle"
      title="Nothing can be booked for that service"
    >
      {@candidates |> elem(1) |> no_candidate_reason()}
    </.callout>

    <div :if={match?({:ok, []}, @candidates)} style="margin-top:var(--s-4)">
      <.empty_state icon="hero-calendar-days" title="No free times in the next two weeks">
        Try a later date, or add availability for a room that provides this.
      </.empty_state>
    </div>

    <div :if={match?({:ok, [_ | _]}, @candidates)} style="margin-top:var(--s-4)">
      <div class="t-small" style="margin-bottom:var(--s-2)">
        Pick a time. These are free right now — another operator may take one before you click,
        which is handled.
      </div>
      <div style="display:flex;flex-wrap:wrap;gap:var(--s-2)">
        <button
          :for={candidate <- @candidates |> elem(1)}
          type="button"
          class="btn btn-ghost btn-sm tnum"
          phx-click={JS.push("book", value: %{starts_at: DateTime.to_iso8601(candidate.starts_at)})}
        >
          {format_utc(candidate.starts_at)}
          <span style="color:var(--color-base-content-muted)">
            · {Map.get(@offices_by_id, candidate.office_id, %{name: "?"}).name}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp no_candidate_reason(:no_eligible_office),
    do: "No office provides the capabilities this service needs. Add them to a room first."

  defp no_candidate_reason(:unknown_service), do: "That service no longer exists."
  defp no_candidate_reason(other), do: "Unavailable (#{inspect(other)})."
end
