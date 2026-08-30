defmodule Scheduling.Booking.RescheduleTest do
  @moduledoc """
  Cancel and reschedule — handing slots back.

  Releasing is not a compare-and-swap: nobody contends for slots an
  appointment already owns. Its failure mode is the opposite of double-booking
  and quieter for it — a release that does not happen **strands** capacity, so
  a room silently offers less than it has and nobody gets an error. These tests
  are mostly about that.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Appointment
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient

  @start ~U[2026-09-07 09:00:00Z]

  defp patient_fixture, do: Repo.insert!(Patient.changeset(%Patient{}, %{name: "Resched"}))

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 1,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids, minutes) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Svc #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => minutes,
        "capability_ids" => capability_ids
      })

    service
  end

  defp slots_for(office, count, minutes \\ 20, from \\ @start) do
    for i <- 0..(count - 1) do
      starts_at = DateTime.add(from, i * minutes * 60, :second)

      Repo.insert!(%Slot{
        office_id: office.id,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, minutes * 60, :second),
        status: :open
      })
    end
  end

  setup do
    cap = capability_fixture("CT scanner")
    office = office_fixture([cap.id])
    slots = slots_for(office, 6)
    service = service_fixture([cap.id], 20)

    {:ok, appointment} =
      Booking.book(%{patient_id: patient_fixture().id, service_code: service.code, from: @start})

    %{cap: cap, office: office, slots: slots, service: service, appointment: appointment}
  end

  describe "cancel" do
    test "releases the slots it held", ctx do
      [held] = ctx.appointment.slots
      assert Booking.get_slot!(held.id).status == :booked

      assert {:ok, cancelled} = Booking.cancel_appointment(ctx.appointment)

      assert cancelled.status == :cancelled
      released = Booking.get_slot!(held.id)
      assert released.status == :open
      assert released.appointment_id == nil
    end

    test "the released slot is immediately bookable again", ctx do
      [held] = ctx.appointment.slots
      {:ok, _} = Booking.cancel_appointment(ctx.appointment)

      {:ok, next} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: ctx.service.code,
          from: @start
        })

      assert Enum.map(next.slots, & &1.id) == [held.id]
    end

    test "is idempotent — cancelling twice strands nothing", ctx do
      {:ok, once} = Booking.cancel_appointment(ctx.appointment)
      assert {:ok, twice} = Booking.cancel_appointment(once)

      assert twice.status == :cancelled
      assert Booking.list_slots(status: :booked) == []
    end

    test "does not touch another appointment's slots", ctx do
      {:ok, other} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: ctx.service.code,
          from: @start
        })

      [other_slot] = other.slots

      {:ok, _} = Booking.cancel_appointment(ctx.appointment)

      # The release is scoped by appointment_id; the neighbour keeps its slot.
      assert Booking.get_slot!(other_slot.id).status == :booked
      assert Booking.get_slot!(other_slot.id).appointment_id == other.id
    end
  end

  describe "reschedule" do
    test "moves to a later run and releases the old slots", ctx do
      [original] = ctx.appointment.slots
      later = DateTime.add(@start, 60 * 60, :second)

      assert {:ok, moved} = Booking.reschedule_appointment(ctx.appointment, from: later)

      assert Appointment.starts_at(moved) == later
      assert Booking.get_slot!(original.id).status == :open
      assert Booking.get_slot!(original.id).appointment_id == nil
    end

    test "keeps the capabilities — it changes when, not what", ctx do
      before = Enum.map(ctx.appointment.required_capabilities, & &1.id)

      {:ok, moved} =
        Booking.reschedule_appointment(ctx.appointment, from: DateTime.add(@start, 3600, :second))

      assert Enum.map(moved.required_capabilities, & &1.id) == before
    end

    test "can move to a time overlapping its current one", ctx do
      # Only possible because the old slots are released before the search.
      # Searching first would never see them as available.
      [original] = ctx.appointment.slots

      assert {:ok, moved} = Booking.reschedule_appointment(ctx.appointment, from: @start)

      assert Enum.map(moved.slots, & &1.id) == [original.id]
      assert Booking.get_slot!(original.id).status == :booked
    end

    test "re-derives the binding, because eligibility may have changed", ctx do
      assert ctx.appointment.binding == :committed

      # A second room gains the capability, so there is now a routing decision.
      other = office_fixture([ctx.cap.id])
      slots_for(other, 4)

      {:ok, moved} = Booking.reschedule_appointment(ctx.appointment, from: @start)

      assert moved.binding == :provisional
    end

    test "rolls back and keeps the original slots when no new run exists", ctx do
      [original] = ctx.appointment.slots
      far_future = ~U[2027-01-01 09:00:00Z]

      assert {:error, :no_available_slots} =
               Booking.reschedule_appointment(ctx.appointment, from: far_future)

      # The critical assertion: a failed reschedule must not strand capacity.
      held = Booking.get_slot!(original.id)
      assert held.status == :booked
      assert held.appointment_id == ctx.appointment.id
      assert Booking.get_appointment!(ctx.appointment.id).status == :booked
    end

    test "preserves the appointment's length across the move" do
      # The appointment does not store the service code, so its length cannot
      # be looked up again — the run it holds *is* the duration. Getting this
      # wrong silently shrinks a 2-hour appointment to 20 minutes, which is why
      # it is asserted rather than assumed.
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      # 09:00-16:00, so there is still a full 2-hour run available from 12:00.
      slots_for(office, 21, 20, ~U[2026-10-05 09:00:00Z])
      service = service_fixture([cap.id], 120)

      {:ok, booked} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: service.code,
          from: ~U[2026-10-05 09:00:00Z]
        })

      assert length(booked.slots) == 6

      {:ok, moved} =
        Booking.reschedule_appointment(booked, from: ~U[2026-10-05 12:00:00Z])

      assert length(moved.slots) == 6

      assert DateTime.diff(Appointment.ends_at(moved), Appointment.starts_at(moved), :second) ==
               120 * 60
    end

    test "refuses a cancelled appointment", ctx do
      {:ok, cancelled} = Booking.cancel_appointment(ctx.appointment)

      assert {:error, :appointment_cancelled} = Booking.reschedule_appointment(cancelled)
    end

    test "a longer service is refused rather than half-placed", ctx do
      # Rescheduling into a window with no contiguous run long enough must
      # leave the appointment exactly as it was.
      [original] = ctx.appointment.slots
      isolated_start = ~U[2026-09-08 09:00:00Z]
      # A lone slot the next day: long enough for nothing.
      slots_for(ctx.office, 1, 20, isolated_start)
      # Extend today's run so the long service can be booked in the first place
      # — setup already consumed the 09:00 slot.
      slots_for(ctx.office, 4, 20, ~U[2026-09-07 11:00:00Z])

      long = service_fixture([ctx.cap.id], 120)

      {:ok, big} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: long.code,
          from: @start
        })

      # Six 20-minute slots from 09:00 satisfy 120 minutes; move it somewhere
      # that cannot.
      assert {:error, :no_available_slots} =
               Booking.reschedule_appointment(big, from: isolated_start)

      assert Booking.get_appointment!(big.id).status == :booked
      assert Booking.get_slot!(original.id).appointment_id == ctx.appointment.id
    end
  end

  describe "capacity is never stranded" do
    test "every slot is either open or owned by a live appointment", ctx do
      later = DateTime.add(@start, 3600, :second)

      {:ok, moved} = Booking.reschedule_appointment(ctx.appointment, from: later)
      {:ok, _} = Booking.cancel_appointment(moved)

      for slot <- Booking.list_slots() do
        case slot.status do
          :open -> assert slot.appointment_id == nil
          :booked -> assert Booking.get_appointment!(slot.appointment_id).status != :cancelled
          _ -> :ok
        end
      end
    end
  end
end
