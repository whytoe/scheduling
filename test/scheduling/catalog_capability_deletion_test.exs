defmodule Scheduling.CatalogCapabilityDeletionTest do
  @moduledoc """
  A capability required by live work cannot be deleted.

  The joins cascade, which is right for the catalog — an office or a routing
  template simply stops offering it — and quietly wrong for anything attached
  to a patient. Cascading there does not make a booking unservable; it makes it
  require **nothing**, silently, with nothing failing and nothing to see.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  @start ~U[2026-09-07 09:00:00Z]

  defp patient_fixture, do: Repo.insert!(Patient.changeset(%Patient{}, %{name: "Cap"}))

  defp capability_fixture do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "CT-#{System.unique_integer([:positive])}"})

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

  describe "an unused capability" do
    test "deletes cleanly" do
      cap = capability_fixture()
      assert {:ok, _} = Catalog.delete_capability(cap)
      assert Catalog.list_capabilities() |> Enum.map(& &1.id) |> Enum.member?(cap.id) == false
    end

    test "deletes even when offices and services offer it — those are catalog facts" do
      cap = capability_fixture()
      office_fixture([cap.id])
      service_fixture([cap.id])

      # Cascading here is correct: the office stops offering it, the template
      # stops requiring it. Nothing about a patient changes.
      assert {:ok, _} = Catalog.delete_capability(cap)
    end
  end

  describe "a capability a patient is waiting on" do
    test "cannot be deleted" do
      cap = capability_fixture()

      {:ok, _entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_capability_ids" => [cap.id]
        })

      assert {:error, changeset} = Catalog.delete_capability(cap)
      assert hd(errors_on(changeset).name) =~ "1 waiting patient"
    end

    test "can be deleted once that work is completed" do
      cap = capability_fixture()
      office = office_fixture([cap.id])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_capability_ids" => [cap.id]
        })

      {:ok, _assigned, _} = Queue.accept(Queue.get_entry!(entry.id))
      assert {:error, _} = Catalog.delete_capability(cap)

      {:ok, _completed} = Queue.complete(Queue.get_entry!(entry.id))
      assert {:ok, _} = Catalog.delete_capability(cap)
      assert office
    end
  end

  describe "a capability a booking needs" do
    setup do
      cap = capability_fixture()
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id])

      {:ok, appointment} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: service.code,
          from: @start
        })

      %{cap: cap, appointment: appointment}
    end

    test "cannot be deleted while the appointment is booked", ctx do
      assert {:error, changeset} = Catalog.delete_capability(ctx.cap)
      assert hd(errors_on(changeset).name) =~ "1 appointment"
    end

    test "cannot be deleted while the patient is in the building", ctx do
      {:ok, _} = Booking.arrive(ctx.appointment)

      assert {:error, changeset} = Catalog.delete_capability(ctx.cap)
      # Arrived counts too — they are here for it.
      assert hd(errors_on(changeset).name) =~ "still required by"
    end

    test "can be deleted once the appointment is cancelled", ctx do
      {:ok, _} = Booking.cancel_appointment(ctx.appointment)

      assert {:ok, _} = Catalog.delete_capability(ctx.cap)
    end

    test "the message names both kinds of work when both exist", ctx do
      {:ok, _entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_capability_ids" => [ctx.cap.id]
        })

      assert {:error, changeset} = Catalog.delete_capability(ctx.cap)
      message = hd(errors_on(changeset).name)

      assert message =~ "1 appointment"
      assert message =~ "1 waiting patient"
    end
  end

  describe "capability_usage/1" do
    test "is public so a UI can explain a refusal before the click, not after" do
      cap = capability_fixture()
      assert Catalog.capability_usage(cap.id) == {0, 0}

      {:ok, _} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_capability_ids" => [cap.id]
        })

      assert {0, 1} = Catalog.capability_usage(cap.id)
    end
  end
end
