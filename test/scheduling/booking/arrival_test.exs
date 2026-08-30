defmodule Scheduling.Booking.ArrivalTest do
  @moduledoc """
  Where booking meets the queue.

  A booked patient arriving produces the same things a walk-in does, so the
  existing lifecycle takes over unchanged. The interesting part is that this
  is the **only** place the binding does anything: committed goes straight to
  its room, provisional goes through the matcher.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Booking
  alias Scheduling.Catalog
  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Booking.Slot

  @start ~U[2026-09-07 09:00:00Z]

  defp patient_fixture, do: Repo.insert!(Patient.changeset(%Patient{}, %{name: "Arrival"}))

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids, capacity \\ 2) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids, minutes \\ 20) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Svc #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => minutes,
        "capability_ids" => capability_ids
      })

    service
  end

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

  defp book(service), do: book(service, patient_fixture())

  defp book(service, patient) do
    {:ok, appointment} =
      Booking.book(%{patient_id: patient.id, service_code: service.code, from: @start})

    appointment
  end

  describe "a committed appointment" do
    setup do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id])
      appointment = book(service)

      assert appointment.binding == :committed
      %{cap: cap, office: office, service: service, appointment: appointment}
    end

    test "is assigned straight to its room — the matcher has nothing to decide", ctx do
      assert {:ok, result} = Booking.arrive(ctx.appointment)

      assert result.entry.status == :assigned
      assert result.entry.assigned_office_id == ctx.office.id
    end

    test "raises a handoff, exactly as accept would", ctx do
      {:ok, result} = Booking.arrive(ctx.appointment)

      assert [handoff] = Handoffs.list_pending_for_office(ctx.office.id)
      assert handoff.queue_entry_id == result.entry.id
      assert handoff.status == :pending
    end

    test "opens a visit and links the entry to both", ctx do
      {:ok, result} = Booking.arrive(ctx.appointment)

      assert result.visit.patient_id == ctx.appointment.patient_id
      assert result.entry.visit_id == result.visit.id
      assert result.entry.appointment_id == ctx.appointment.id
    end

    test "carries the appointment's capabilities onto the entry", ctx do
      {:ok, result} = Booking.arrive(ctx.appointment)

      assert Enum.map(result.entry.required_capabilities, & &1.name) == [ctx.cap.name]
    end

    test "marks the appointment arrived", ctx do
      {:ok, result} = Booking.arrive(ctx.appointment)
      assert result.appointment.status == :arrived
    end

    test "keeps its slots booked — the room's time is being spent, not freed", ctx do
      [slot] = ctx.appointment.slots
      {:ok, _} = Booking.arrive(ctx.appointment)

      assert Booking.get_slot!(slot.id).status == :booked
    end

    test "records the usual lifecycle events", ctx do
      {:ok, _} = Booking.arrive(ctx.appointment)

      assert [_] = Audit.list_events(type: "visit.created")
      assert [_] = Audit.list_events(type: "queue_entry.created")
    end
  end

  describe "a provisional appointment" do
    setup do
      cap = capability_fixture("Consult room")
      a = office_fixture([cap.id])
      b = office_fixture([cap.id])
      slots_for(a, 4)
      slots_for(b, 4)
      service = service_fixture([cap.id])
      appointment = book(service)

      assert appointment.binding == :provisional
      %{cap: cap, a: a, b: b, service: service, appointment: appointment}
    end

    test "is left waiting for the matcher rather than pinned", ctx do
      assert {:ok, result} = Booking.arrive(ctx.appointment)

      assert result.entry.status == :waiting
      assert result.entry.assigned_office_id == nil
    end

    test "no handoff is raised until it is accepted", ctx do
      {:ok, _} = Booking.arrive(ctx.appointment)

      assert Handoffs.list_pending() == []
    end

    test "goes through the normal accept flow, and the matcher may place it anywhere",
         ctx do
      {:ok, result} = Booking.arrive(ctx.appointment)

      assert {:ok, assigned, _result} = Queue.accept(Queue.get_entry!(result.entry.id))
      assert assigned.status == :assigned
      assert assigned.assigned_office_id in [ctx.a.id, ctx.b.id]
    end

    test "the matcher uses live capacity, not what was true at booking", ctx do
      # Fill office A to capacity after the booking was made. Assigned
      # directly rather than through accept/2, so the fill is deterministic —
      # the matcher would otherwise spread the fillers across both rooms and
      # the test would pass or fail on best-fit ordering rather than on the
      # thing it is checking.
      for _ <- 1..ctx.a.intake_capacity do
        {:ok, entry} =
          Queue.create_entry(%{
            "patient_id" => patient_fixture().id,
            "required_capability_ids" => [ctx.cap.id]
          })

        entry
        |> Scheduling.Queue.QueueEntry.assignment_changeset(ctx.a)
        |> Repo.update!()
      end

      assert Queue.current_loads()[ctx.a.id] == ctx.a.intake_capacity

      {:ok, result} = Booking.arrive(ctx.appointment)
      {:ok, assigned, _} = Queue.accept(Queue.get_entry!(result.entry.id))

      # A is full, so the only room left is B — decided now, not at booking.
      assert assigned.assigned_office_id == ctx.b.id
    end
  end

  describe "arriving twice" do
    test "returns the original visit and entry rather than opening a second" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      appointment = book(service_fixture([cap.id]))

      {:ok, first} = Booking.arrive(appointment)
      {:ok, second} = Booking.arrive(Booking.get_appointment!(appointment.id))

      assert second.entry.id == first.entry.id
      assert second.visit.id == first.visit.id
      assert length(Queue.list_waiting_entries()) + length(Queue.list_active_entries()) == 1
    end
  end

  describe "refusals" do
    test "a cancelled appointment cannot arrive" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      appointment = book(service_fixture([cap.id]))
      {:ok, cancelled} = Booking.cancel_appointment(appointment)

      assert {:error, :appointment_cancelled} = Booking.arrive(cancelled)
    end

    test "nothing is created when arrival is refused" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      appointment = book(service_fixture([cap.id]))
      {:ok, cancelled} = Booking.cancel_appointment(appointment)

      {:error, _} = Booking.arrive(cancelled)

      assert Queue.list_waiting_entries() == []
      assert Audit.list_events(type: "visit.created") == []
    end
  end
end
