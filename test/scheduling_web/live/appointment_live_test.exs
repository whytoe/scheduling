defmodule SchedulingWeb.AppointmentLiveTest do
  @moduledoc """
  The operator booking screen.

  Runs with auth **enabled** (`setup_oidc_provider`), because part of what this
  screen asserts is that booking is an *operator* activity — reachable without
  the admin role that `/availability` requires. Testing with auth off would
  assert nothing about that.

  `async: false` — the fake provider writes application env.
  """
  use SchedulingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Scheduling.OidcProvider

  alias Scheduling.Auth.Identity
  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Repo
  alias SchedulingWeb.Plugs.BrowserAuth

  # Far enough ahead that "earliest date = today" in the form still finds them.
  @start DateTime.utc_now() |> DateTime.add(2 * 24 * 3600, :second) |> DateTime.truncate(:second)

  setup :setup_oidc_provider

  defp sign_in(conn, roles) do
    identity =
      %{
        "sub" => "user-1",
        "email" => "acasey@example.org",
        "sid" => "session-1",
        "name" => "A. Casey",
        "astrum_roles" => roles
      }
      |> Identity.from_claims("scheduling")

    identity = %{identity | expires_at: System.system_time(:second) + 3600}

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(BrowserAuth.identity_key(), Identity.to_session(identity))
  end

  defp operator(conn), do: sign_in(conn, ["operator"])

  defp patient_fixture(name \\ nil) do
    Repo.insert!(
      Patient.changeset(%Patient{}, %{
        name: name || "Patient #{System.unique_integer([:positive])}"
      })
    )
  end

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids, name) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => name,
        "intake_capacity" => 2,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids, minutes \\ 20) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Service #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => minutes,
        "capability_ids" => capability_ids
      })

    service
  end

  # `0..(count - 1)` counts *down* when count is 0, inserting duplicates that
  # trip the (office_id, starts_at) unique index. Guard rather than leave the
  # trap for the next person.
  defp slots_for(_office, 0), do: []

  defp slots_for(office, count) do
    for i <- 0..(count - 1) do
      starts_at = DateTime.add(@start, i * 20 * 60, :second)

      Repo.insert!(%Slot{
        office_id: office.id,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, 20 * 60, :second),
        status: :open
      })
    end
  end

  defp bookable do
    cap = capability_fixture("CT scanner")
    office = office_fixture([cap.id], "Imaging Suite")
    slots_for(office, 6)
    %{cap: cap, office: office, service: service_fixture([cap.id]), patient: patient_fixture()}
  end

  defp book!(ctx) do
    {:ok, appointment} =
      Booking.book(%{
        patient_id: ctx.patient.id,
        service_code: ctx.service.code,
        from: @start
      })

    appointment
  end

  describe "access" do
    test "an operator can reach it — this is shift work, not administration", %{conn: conn} do
      assert {:ok, _live, html} = live(operator(conn), ~p"/appointments")
      assert html =~ "Appointments"
    end

    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/appointments")
    end
  end

  describe "the list" do
    test "shows an empty state when nothing is booked", %{conn: conn} do
      {:ok, _live, html} = live(operator(conn), ~p"/appointments")
      assert html =~ "Nothing here"
    end

    test "shows patient, room, equipment and time", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)

      {:ok, _live, html} = live(operator(conn), ~p"/appointments")

      assert html =~ ctx.patient.name
      assert html =~ "Imaging Suite"
      assert html =~ ctx.cap.name
      assert html =~ "UTC"
      assert html =~ "appointment-#{appointment.id}"
    end

    test "never names the service — only the equipment it implied", %{conn: conn} do
      ctx = bookable()
      _appointment = book!(ctx)

      {:ok, _live, html} = live(operator(conn), ~p"/appointments")

      # The appointment stores capabilities, not the service. Showing the
      # service would mean looking one up — the leak docs/data-boundary.md
      # exists to prevent.
      refute html =~ ctx.service.name
      assert html =~ ctx.cap.name
    end

    test "explains what the binding means rather than showing the bare word", %{conn: conn} do
      ctx = bookable()
      _appointment = book!(ctx)

      {:ok, _live, html} = live(operator(conn), ~p"/appointments")

      # One eligible office, so committed — and "committed" alone tells an
      # operator nothing.
      assert html =~ "Only this room can provide it"
      assert html =~ ctx.office.name
    end

    test "does not name a room for a provisional appointment", %{conn: conn} do
      # The room holding the slots is where the *time* is reserved, not where
      # the patient will go — the matcher may send them elsewhere on arrival,
      # and those differ precisely when binding is provisional. Naming it would
      # invite someone to walk the patient to the wrong room.
      ctx = bookable()
      second = office_fixture([ctx.cap.id], "Second Room")
      slots_for(second, 4)

      appointment = book!(ctx)
      assert appointment.binding == :provisional

      {:ok, _live, html} = live(operator(conn), ~p"/appointments")

      assert html =~ "Decided on arrival"
      assert html =~ "Several rooms can"
      refute html =~ ctx.office.name
      refute html =~ second.name
    end

    test "filters by status", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)
      {:ok, _} = Booking.cancel_appointment(appointment)

      {:ok, live, _html} = live(operator(conn), ~p"/appointments")

      # Default filter is booked, so a cancelled one is hidden.
      refute render(live) =~ ctx.patient.name

      html = live |> element("button[role=tab]", "Cancelled") |> render_click()
      assert html =~ ctx.patient.name
    end
  end

  describe "booking" do
    test "offers real candidate times once a patient and service are chosen", %{conn: conn} do
      ctx = bookable()

      {:ok, live, html} = live(operator(conn), ~p"/appointments/new")
      assert html =~ "Choose a patient and a service"

      html =
        live
        |> form("form[phx-change=booking_change]",
          booking: %{
            patient_id: to_string(ctx.patient.id),
            service_code: ctx.service.code,
            from: Date.utc_today() |> Date.to_iso8601()
          }
        )
        |> render_change()

      assert html =~ "Pick a time"
      assert html =~ "Imaging Suite"
    end

    test "books the chosen time end to end", %{conn: conn} do
      ctx = bookable()

      {:ok, live, _html} = live(operator(conn), ~p"/appointments/new")

      live
      |> form("form[phx-change=booking_change]",
        booking: %{
          patient_id: to_string(ctx.patient.id),
          service_code: ctx.service.code,
          from: Date.utc_today() |> Date.to_iso8601()
        }
      )
      |> render_change()

      render_click(live, "book", %{"starts_at" => DateTime.to_iso8601(@start)})

      assert [appointment] = Booking.list_appointments()
      assert appointment.patient_id == ctx.patient.id
      assert Scheduling.Booking.Appointment.starts_at(appointment) == @start
    end

    test "a service no room can provide is refused with something actionable", %{conn: conn} do
      unprovided = capability_fixture("MRI")
      service = service_fixture([unprovided.id])
      patient = patient_fixture()

      {:ok, live, _html} = live(operator(conn), ~p"/appointments/new")

      html =
        live
        |> form("form[phx-change=booking_change]",
          booking: %{
            patient_id: to_string(patient.id),
            service_code: service.code,
            from: Date.utc_today() |> Date.to_iso8601()
          }
        )
        |> render_change()

      assert html =~ "No office provides the capabilities this service needs"
    end

    test "a time taken since it was displayed fails as an ordinary outcome", %{conn: conn} do
      ctx = bookable()

      {:ok, live, _html} = live(operator(conn), ~p"/appointments/new")

      live
      |> form("form[phx-change=booking_change]",
        booking: %{
          patient_id: to_string(ctx.patient.id),
          service_code: ctx.service.code,
          from: Date.utc_today() |> Date.to_iso8601()
        }
      )
      |> render_change()

      # Another operator takes every slot between the preview and the click.
      Repo.update_all(Slot, set: [status: :booked])

      html = render_click(live, "book", %{"starts_at" => DateTime.to_iso8601(@start)})

      # A refreshed list and a plain explanation, not an error page.
      assert html =~ "taken while you were choosing"
      assert Booking.list_appointments() == []
    end
  end

  describe "arrive" do
    test "puts the patient in the queue and marks the appointment arrived", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)

      {:ok, live, _html} = live(operator(conn), ~p"/appointments")

      html = render_click(live, "arrive", %{"id" => appointment.id})

      assert html =~ "Checked in"
      assert Booking.get_appointment!(appointment.id).status == :arrived

      # Committed, so it went straight through to its room.
      assert [entry] = Queue.list_active_entries()
      assert entry.assigned_office_id == ctx.office.id
    end
  end

  describe "cancel" do
    test "releases the slots it held", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)
      [held] = appointment.slots

      {:ok, live, _html} = live(operator(conn), ~p"/appointments")

      render_click(live, "confirm_cancel", %{"id" => appointment.id})
      html = render_click(live, "cancel_appointment", %{"id" => appointment.id})

      assert html =~ "free for someone else"
      assert Booking.get_appointment!(appointment.id).status == :cancelled
      assert Booking.get_slot!(held.id).status == :open
    end

    test "names the consequence before doing it", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)

      {:ok, live, _html} = live(operator(conn), ~p"/appointments")
      html = render_click(live, "confirm_cancel", %{"id" => appointment.id})

      assert html =~ "released for someone else to book"
      assert html =~ "does not notify the patient"
      # Still booked — the dialog has not been confirmed.
      assert Booking.get_appointment!(appointment.id).status == :booked
    end
  end

  describe "reschedule" do
    test "moves the appointment and frees the original slot", %{conn: conn} do
      ctx = bookable()
      appointment = book!(ctx)
      [original] = appointment.slots

      {:ok, live, _html} = live(operator(conn), ~p"/appointments")

      later = DateTime.add(@start, 24 * 3600, :second)

      # Give the later day some availability to move into.
      for i <- 0..2 do
        starts_at = DateTime.add(later, i * 20 * 60, :second)

        Repo.insert!(%Slot{
          office_id: ctx.office.id,
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 20 * 60, :second),
          status: :open
        })
      end

      render_click(live, "reschedule", %{
        "appointment_id" => appointment.id,
        "from" => later |> DateTime.to_date() |> Date.to_iso8601()
      })

      moved = Booking.get_appointment!(appointment.id)
      moved_start = Scheduling.Booking.Appointment.starts_at(moved)

      # Not pinned to an exact instant: the engine takes the earliest run at or
      # after the requested day, and the original run can spill past midnight,
      # so "the slot I made" is not necessarily the first candidate. What
      # matters is that it moved forward and gave the old slot back.
      assert DateTime.compare(moved_start, @start) == :gt
      assert Booking.get_slot!(original.id).status == :open
      assert Booking.get_slot!(original.id).appointment_id == nil
    end
  end
end
