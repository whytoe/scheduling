defmodule Scheduling.QueueEndingsTest do
  @moduledoc """
  Cancelling and not-showing, which are different facts about a clinic's day.

  Both free capacity and both end the entry. "Told us they were not coming" and
  "did not turn up" are not the same thing, and a clinic that collapses them
  cannot tell a well-run list from a badly-run one.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp entry_fixture do
    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Ending Patient"}))
    {:ok, entry} = Queue.create_entry(%{"patient_id" => patient.id})
    entry
  end

  defp office_fixture do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2
      })

    office
  end

  # No code path produces an :in_service entry — see sc-hdd — so the only way to
  # test the rules about one is to write the status directly.
  defp in_service_fixture do
    office_fixture()
    entry = entry_fixture()
    {:ok, _, _} = Queue.accept(Queue.get_entry!(entry.id))

    Queue.get_entry!(entry.id)
    |> Ecto.Changeset.change(status: :in_service)
    |> Repo.update!()
  end

  defp events_for(entry_id) do
    Audit.list_events(%{})
    |> Enum.filter(&(&1.queue_entry_id == entry_id))
    |> Enum.map(& &1.type)
  end

  describe "cancel/2" do
    test "ends a waiting entry and records why" do
      entry = entry_fixture()

      assert {:ok, cancelled} = Queue.cancel(entry, reason: "patient called ahead")
      assert cancelled.status == :cancelled
      assert "queue_entry.cancelled" in events_for(entry.id)
    end

    test "frees the office when the patient had already been assigned" do
      office_fixture()
      entry = entry_fixture()
      {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      assert Queue.current_loads()[assigned.assigned_office_id] == 1
      assert {:ok, _} = Queue.cancel(Queue.get_entry!(entry.id))
      assert Map.get(Queue.current_loads(), assigned.assigned_office_id, 0) == 0
    end

    test "is refused once service has begun" do
      # Cancelling would erase that a clinician's time was spent.
      #
      # Set directly rather than through a context function, because NOTHING
      # transitions an entry to :in_service — the status is declared, rendered
      # and filterable, and never written. See sc-hdd. When that is fixed this
      # should go through whatever performs the transition.
      entry = in_service_fixture()

      assert {:error, changeset} = Queue.cancel(entry)
      assert {message, _} = changeset.errors[:status]
      assert message =~ "in_service entry cannot become cancelled"
    end

    test "is refused on an entry that already ended" do
      entry = entry_fixture()
      {:ok, _} = Queue.cancel(entry)

      assert {:error, changeset} = Queue.cancel(Queue.get_entry!(entry.id))
      assert {message, _} = changeset.errors[:status]
      assert message =~ "finished"
    end
  end

  describe "no_show/2" do
    test "ends a waiting entry" do
      entry = entry_fixture()

      assert {:ok, missed} = Queue.no_show(entry)
      assert missed.status == :no_show
      assert "queue_entry.no_show" in events_for(entry.id)
    end

    test "is valid from assigned — capacity was held and wasted" do
      # The case the status exists to count. A patient given a room who never
      # appears is not the same as one who never got a room.
      office_fixture()
      entry = entry_fixture()
      {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      assert {:ok, missed} = Queue.no_show(Queue.get_entry!(entry.id))
      assert missed.status == :no_show
      assert Map.get(Queue.current_loads(), assigned.assigned_office_id, 0) == 0
    end

    test "is refused from in_service — they are in the room" do
      entry = in_service_fixture()

      assert {:error, changeset} = Queue.no_show(entry)
      assert changeset.errors[:status]
    end
  end

  describe "the audit row" do
    test "records where the entry came from, not only where it went" do
      # "Cancelled" alone does not say whether a room was held. from_status
      # does, and capacity reporting needs it.
      office_fixture()
      entry = entry_fixture()
      {:ok, _, _} = Queue.accept(Queue.get_entry!(entry.id))
      {:ok, _} = Queue.cancel(Queue.get_entry!(entry.id))

      event =
        Audit.list_events(%{})
        |> Enum.find(&(&1.queue_entry_id == entry.id and &1.type == "queue_entry.cancelled"))

      assert event.payload["from_status"] == "assigned"
    end

    test "carries no clinical content" do
      # The reason is operator-supplied free text and rides into an
      # append-only row that fans out to every webhook subscriber. Whatever
      # else changes here, that has to stay true — see docs/data-boundary.md.
      entry = entry_fixture()
      {:ok, _} = Queue.cancel(entry, reason: "patient called ahead")

      event =
        Audit.list_events(%{})
        |> Enum.find(&(&1.queue_entry_id == entry.id and &1.type == "queue_entry.cancelled"))

      refute Map.has_key?(event.payload, "diagnosis_id")
      refute Map.has_key?(event.payload, "required_compliance_refs")
    end
  end
end
