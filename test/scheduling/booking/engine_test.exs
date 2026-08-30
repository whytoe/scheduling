defmodule Scheduling.Booking.EngineTest do
  @moduledoc """
  The booking engine: service resolution, binding derivation, contiguous-run
  finding, and the reservation compare-and-swap.

  On the concurrency tests — see the `reservation` describe block. The Ecto
  sandbox routes every process through one connection in shared mode, so
  processes cannot genuinely race at the database level and a "spawn N tasks"
  test would look rigorous while proving nothing. The tests here exercise the
  compare-and-swap by controlling the interleaving instead.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Appointment
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient

  @start ~U[2026-09-07 09:00:00Z]

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Booking Test"}))
  end

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids, capacity \\ 1) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids, duration_minutes) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Service #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => duration_minutes,
        "capability_ids" => capability_ids
      })

    service
  end

  # Slots are inserted directly: generation has its own tests, and building
  # them here keeps the run shapes explicit.
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

  defp book(attrs), do: Booking.book(Map.merge(%{from: @start}, attrs))

  describe "binding derivation" do
    test "one eligible office means committed — there is nothing to decide" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 2)
      service = service_fixture([cap.id], 20)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert appointment.binding == :committed
    end

    test "several eligible offices mean provisional" do
      cap = capability_fixture("Consult room")
      a = office_fixture([cap.id])
      b = office_fixture([cap.id])
      slots_for(a, 2)
      slots_for(b, 2)
      service = service_fixture([cap.id], 20)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert appointment.binding == :provisional
    end

    test "no eligible office refuses the booking" do
      needed = capability_fixture("MRI")
      other = capability_fixture("XRay")
      office = office_fixture([other.id])
      slots_for(office, 4)
      service = service_fixture([needed.id], 20)

      assert {:error, :no_eligible_office} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})
    end

    test "an office with zero intake capacity is not bookable" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id], 0)
      slots_for(office, 4)
      service = service_fixture([cap.id], 20)

      assert {:error, :no_eligible_office} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})
    end

    test "a busy queue does not make a future slot unbookable" do
      # Matching.eligible_offices/3 filters on live free capacity, which is
      # right for the walk-in matcher and wrong here: a room full right now is
      # still bookable for tomorrow. The engine must not pass live loads.
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id], 1)
      slots_for(office, 2)
      service = service_fixture([cap.id], 20)

      entry_patient = patient_fixture()

      {:ok, entry} =
        Scheduling.Queue.create_entry(%{
          "patient_id" => entry_patient.id,
          "required_capability_ids" => [cap.id]
        })

      {:ok, _assigned, _result} = Scheduling.Queue.accept(Scheduling.Queue.get_entry!(entry.id))
      assert Scheduling.Queue.current_loads()[office.id] == 1

      assert {:ok, _appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})
    end
  end

  describe "finding a run" do
    test "a service needing one slot takes one" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 3)
      service = service_fixture([cap.id], 20)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert length(appointment.slots) == 1
    end

    test "a 40-minute service on a 20-minute calendar takes two consecutive slots" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id], 40)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert length(appointment.slots) == 2
      assert Appointment.starts_at(appointment) == @start
      assert Appointment.ends_at(appointment) == DateTime.add(@start, 40 * 60, :second)
    end

    test "a gap breaks the run — booking does not span a lunch break" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      # One slot at 09:00, then a gap, then two contiguous from 11:00.
      slots_for(office, 1, 20, @start)
      slots_for(office, 2, 20, ~U[2026-09-07 11:00:00Z])
      service = service_fixture([cap.id], 40)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      # The lone 09:00 slot cannot satisfy 40 minutes, so the run starts at 11.
      assert Appointment.starts_at(appointment) == ~U[2026-09-07 11:00:00Z]
      assert length(appointment.slots) == 2
    end

    test "no run long enough is refused" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      # Three isolated slots, none contiguous.
      slots_for(office, 1, 20, @start)
      slots_for(office, 1, 20, ~U[2026-09-07 11:00:00Z])
      slots_for(office, 1, 20, ~U[2026-09-07 13:00:00Z])
      service = service_fixture([cap.id], 40)

      assert {:error, :no_available_slots} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})
    end

    test "slots before the requested start are not used" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id], 20)

      later = DateTime.add(@start, 40 * 60, :second)

      assert {:ok, appointment} =
               Booking.book(%{
                 patient_id: patient_fixture().id,
                 service_code: service.code,
                 from: later
               })

      assert Appointment.starts_at(appointment) == later
    end

    test "a blocked slot is not bookable" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      [first | _] = slots_for(office, 2)
      {:ok, _} = Booking.block_slot(first)
      service = service_fixture([cap.id], 20)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert Appointment.starts_at(appointment) == DateTime.add(@start, 20 * 60, :second)
    end
  end

  describe "the data boundary" do
    test "the service code is not stored on the appointment" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 2)
      service = service_fixture([cap.id], 20)

      {:ok, appointment} = book(%{patient_id: patient_fixture().id, service_code: service.code})

      refute Map.has_key?(appointment, :service_code)
      refute :service_code in Appointment.__schema__(:fields)
      refute :diagnosis_id in Appointment.__schema__(:fields)

      # What it keeps is the equipment the service implied.
      assert Enum.map(appointment.required_capabilities, & &1.name) == [cap.name]
    end

    test "a booking with no requirement at all is refused" do
      # Found by the API work. An empty requirement matches every office, so
      # this would quietly reserve the first free slot anywhere for an
      # unspecified purpose. Almost always a caller that forgot the code.
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 2)

      assert {:error, :no_service_specified} = book(%{patient_id: patient_fixture().id})
      assert Booking.list_appointments() == []
      assert Booking.list_slots(status: :booked) == []
    end

    test "an explicit empty capability list is honoured as 'any room'" do
      # Distinct from omitting it: the caller has said what they want.
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 2)

      assert {:ok, appointment} =
               book(%{patient_id: patient_fixture().id, required_capability_ids: []})

      assert appointment.required_capabilities == []
    end

    test "an unknown service code is refused rather than booked blind" do
      assert {:error, :unknown_service} =
               book(%{patient_id: patient_fixture().id, service_code: "svc_nope"})
    end
  end

  describe "reservation" do
    setup do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots = slots_for(office, 2)
      service = service_fixture([cap.id], 20)

      %{cap: cap, office: office, slots: slots, service: service}
    end

    test "booking marks the slots booked and links them", ctx do
      {:ok, appointment} =
        book(%{patient_id: patient_fixture().id, service_code: ctx.service.code})

      [slot] = appointment.slots
      reloaded = Booking.get_slot!(slot.id)

      assert reloaded.status == :booked
      assert reloaded.appointment_id == appointment.id
    end

    test "a slot taken before the search is simply not offered", ctx do
      # The ordinary case: the competitor won early enough that find_run never
      # sees the slot. This is NOT the compare-and-swap path — see below.
      service = service_fixture([ctx.cap.id], 40)
      [first, _second] = ctx.slots

      Repo.update_all(from(s in Slot, where: s.id == ^first.id), set: [status: :booked])

      assert {:error, :no_available_slots} =
               book(%{patient_id: patient_fixture().id, service_code: service.code})

      assert Booking.list_appointments() == []
    end

    test "claim_slots/3 refuses when a slot was taken after the search", ctx do
      # THE compare-and-swap, driven directly.
      #
      # It cannot be reached through book/1 in a test: the sandbox routes every
      # process through one connection, so nothing can take a slot in the
      # window between find_run and the reservation. Driving claim_slots/3
      # exercises exactly the code path a genuine race takes.
      [first, second] = ctx.slots

      appointment =
        Repo.insert!(%Appointment{
          patient_id: patient_fixture().id,
          binding: :committed,
          status: :booked
        })

      # The competitor, landing after our search read both as open.
      Repo.update_all(from(s in Slot, where: s.id == ^first.id), set: [status: :booked])

      assert {:error, :slots_taken} =
               Booking.Engine.claim_slots([first.id, second.id], appointment.id)
    end

    test "claim_slots/3 takes every slot when all are open", ctx do
      [first, second] = ctx.slots

      appointment =
        Repo.insert!(%Appointment{
          patient_id: patient_fixture().id,
          binding: :committed,
          status: :booked
        })

      assert {:ok, 2} = Booking.Engine.claim_slots([first.id, second.id], appointment.id)

      assert Booking.get_slot!(first.id).status == :booked
      assert Booking.get_slot!(second.id).appointment_id == appointment.id
    end

    test "a rolled-back transaction releases whatever was claimed", ctx do
      # claim_slots/3 reports failure but does not itself undo the rows it did
      # claim — the surrounding transaction is what releases them. That split
      # is only safe if the rollback genuinely works, so assert it.
      [first, second] = ctx.slots

      appointment =
        Repo.insert!(%Appointment{
          patient_id: patient_fixture().id,
          binding: :committed,
          status: :booked
        })

      Repo.transaction(fn ->
        {:ok, 2} = Booking.Engine.claim_slots([first.id, second.id], appointment.id)
        Repo.rollback(:deliberate)
      end)

      assert Booking.get_slot!(first.id).status == :open
      assert Booking.get_slot!(second.id).status == :open
      assert Booking.get_slot!(first.id).appointment_id == nil
    end
  end

  describe "idempotency" do
    test "booking twice with the same external_ref returns the original" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id], 20)
      patient = patient_fixture()

      {:ok, first} =
        book(%{patient_id: patient.id, service_code: service.code, external_ref: "ext-1"})

      {:ok, second} =
        book(%{patient_id: patient.id, service_code: service.code, external_ref: "ext-1"})

      assert first.id == second.id
      assert length(Booking.list_appointments()) == 1
    end

    test "different refs book separately" do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id], 20)
      patient = patient_fixture()

      {:ok, a} = book(%{patient_id: patient.id, service_code: service.code, external_ref: "e1"})
      {:ok, b} = book(%{patient_id: patient.id, service_code: service.code, external_ref: "e2"})

      refute a.id == b.id
      assert Appointment.starts_at(b) == DateTime.add(@start, 20 * 60, :second)
    end
  end
end
