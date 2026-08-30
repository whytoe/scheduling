defmodule Scheduling.Booking.BrokenCommitmentTest do
  @moduledoc """
  A committed appointment is pinned to the **only** office that could serve it.
  If that office later loses the capability, the booking becomes unfulfillable
  and does so silently — nothing fails until the patient is at the desk.

  These cover the scan that catches it. It is a scan rather than an event
  because a capability can disappear by several routes, and a hook that misses
  one is worse than no hook: it looks like coverage.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient

  @start ~U[2026-09-07 09:00:00Z]

  defp patient_fixture, do: Repo.insert!(Patient.changeset(%Patient{}, %{name: "Committed"}))

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Svc #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => 20,
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

  setup do
    cap = capability_fixture("CT scanner")
    office = office_fixture([cap.id])
    slots_for(office, 4)
    service = service_fixture([cap.id])

    {:ok, appointment} =
      Booking.book(%{patient_id: patient_fixture().id, service_code: service.code, from: @start})

    assert appointment.binding == :committed
    %{cap: cap, office: office, service: service, appointment: appointment}
  end

  test "a healthy commitment raises nothing", _ctx do
    assert Booking.broken_commitments() == []
  end

  test "raises when the pinned office loses the capability", ctx do
    {:ok, _} = Offices.update_office(ctx.office, %{"capability_ids" => []})

    assert [{appointment, missing}] = Booking.broken_commitments()
    assert appointment.id == ctx.appointment.id
    assert missing == [ctx.cap.name]
  end

  @tag :documents_a_gap
  test "deleting the capability outright is NOT caught — a separate hole", ctx do
    # Deleting a capability cascades through appointment_capabilities, so the
    # appointment stops requiring it rather than becoming unservable. Nothing
    # is "missing" because nothing is required any more.
    #
    # That is arguably worse than what this scan targets: a booking made for a
    # CT scan silently becomes a booking for nothing. But it is a different
    # failure — the requirement vanished, not the room's ability to meet it —
    # and folding it in here would need a rule that cannot distinguish it from
    # a legitimate no-capability booking in a single-office deployment.
    #
    # Recorded as its own bead rather than half-handled. This test exists so
    # the behaviour is known, not because it is desirable.
    {:ok, _} = Catalog.delete_capability(ctx.cap)

    assert Booking.broken_commitments() == []
    assert Booking.get_appointment!(ctx.appointment.id).required_capabilities == []
  end

  test "names only the capabilities actually missing", ctx do
    second = capability_fixture("Contrast")

    {:ok, office} =
      Offices.update_office(ctx.office, %{"capability_ids" => [ctx.cap.id, second.id]})

    service = service_fixture([ctx.cap.id, second.id])

    {:ok, _appointment} =
      Booking.book(%{patient_id: patient_fixture().id, service_code: service.code, from: @start})

    # Drop only the second.
    {:ok, _} = Offices.update_office(office, %{"capability_ids" => [ctx.cap.id]})

    broken = Booking.broken_commitments()
    assert Enum.any?(broken, fn {_a, missing} -> missing == [second.name] end)
  end

  test "does not raise for a provisional appointment" do
    # Provisional means several offices could serve it, so one losing the
    # capability is not a problem — the matcher will route elsewhere.
    cap = capability_fixture("Consult room")
    a = office_fixture([cap.id])
    b = office_fixture([cap.id])
    slots_for(a, 4)
    slots_for(b, 4)
    service = service_fixture([cap.id])

    {:ok, appointment} =
      Booking.book(%{patient_id: patient_fixture().id, service_code: service.code, from: @start})

    assert appointment.binding == :provisional

    {:ok, _} = Offices.update_office(a, %{"capability_ids" => []})
    {:ok, _} = Offices.update_office(b, %{"capability_ids" => []})

    assert Booking.broken_commitments() == []
  end

  test "does not raise once the patient has arrived", ctx do
    {:ok, _} = Booking.arrive(ctx.appointment)
    {:ok, _} = Offices.update_office(ctx.office, %{"capability_ids" => []})

    # Past the point where the room mattered — they are already in it.
    assert Booking.broken_commitments() == []
  end

  test "does not raise for a cancelled appointment", ctx do
    {:ok, _} = Booking.cancel_appointment(ctx.appointment)
    {:ok, _} = Offices.update_office(ctx.office, %{"capability_ids" => []})

    assert Booking.broken_commitments() == []
  end

  test "raises with no missing list when the office is gone entirely", ctx do
    # Deleting an office cascades to its slots, so the appointment holds none
    # and there is no office left to compare against. Same problem, different
    # route — and it must not crash the scan.
    {:ok, _} = Offices.delete_office(ctx.office)

    assert [{appointment, missing}] = Booking.broken_commitments()
    assert appointment.id == ctx.appointment.id
    assert missing == []
  end

  test "clears once the capability is restored", ctx do
    {:ok, stripped} = Offices.update_office(ctx.office, %{"capability_ids" => []})
    assert length(Booking.broken_commitments()) == 1

    # Reload rather than reusing ctx.office: its preloaded capabilities are
    # stale after the strip, and put_assoc against a stale struct would decide
    # nothing had changed.
    {:ok, _} = Offices.update_office(stripped, %{"capability_ids" => [ctx.cap.id]})
    assert Booking.broken_commitments() == []
  end
end
