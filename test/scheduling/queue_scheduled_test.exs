defmodule Scheduling.QueueScheduledTest do
  @moduledoc """
  An entry booked for a time that has not arrived.

  The queueing service books a patient for 10:00 and tells us at 08:30. The
  property that matters is that the matcher cannot see that entry until 10:00 —
  otherwise a patient is given a room ninety minutes early, and a room is held
  for ninety minutes.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Scheduled Patient"}))
  end

  defp office_fixture do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2
      })

    office
  end

  defp in_hours(n), do: DateTime.utc_now() |> DateTime.add(n, :hour) |> DateTime.truncate(:second)

  describe "creating an entry with a future time" do
    test "is created scheduled, not waiting" do
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(2)
        })

      assert entry.status == :scheduled
    end

    test "is invisible to the waiting list" do
      Queue.create_entry(%{"patient_id" => patient_fixture().id, "scheduled_for" => in_hours(2)})

      assert Queue.list_waiting_entries() == []
    end

    test "cannot be accepted — the matcher must not reach it" do
      # The property this whole status exists for. A filtered board alone would
      # still let accept place the patient in a room ninety minutes early.
      office_fixture()

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(2)
        })

      assert {:error, changeset} = Queue.accept(Queue.get_entry!(entry.id))
      assert changeset.errors[:status]
    end

    test "accepts an ISO 8601 string, since that is what the API sends" do
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => DateTime.to_iso8601(in_hours(3))
        })

      assert entry.status == :scheduled
    end
  end

  describe "creating an entry with a past or absent time" do
    test "a walk-in is waiting, as before" do
      {:ok, entry} = Queue.create_entry(%{"patient_id" => patient_fixture().id})
      assert entry.status == :waiting
    end

    test "a time already passed is waiting, not scheduled" do
      # A booking made late. Leaving it scheduled would hide the patient until
      # the next promoter pass for no reason.
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(-1)
        })

      assert entry.status == :waiting
    end

    test "a malformed time does not silently become a walk-in" do
      # Treating unparseable input as "now" would place a patient in the queue
      # immediately on the strength of a typo.
      assert {:error, changeset} =
               Queue.create_entry(%{
                 "patient_id" => patient_fixture().id,
                 "scheduled_for" => "next tuesday"
               })

      assert changeset.errors[:scheduled_for]
    end
  end

  describe "promote_due_entries/1" do
    test "promotes an entry whose time has arrived" do
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(2)
        })

      assert {:ok, 1} = Queue.promote_due_entries(DateTime.add(DateTime.utc_now(), 3, :hour))
      assert Queue.get_entry!(entry.id).status == :waiting
    end

    test "leaves an entry whose time has not" do
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(4)
        })

      assert {:ok, 0} = Queue.promote_due_entries()
      assert Queue.get_entry!(entry.id).status == :scheduled
    end

    test "writes an audit row, because every other transition does" do
      # A promotion that happened implicitly inside a query could not do this,
      # which is half the reason it is a real transition.
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(1)
        })

      {:ok, 1} = Queue.promote_due_entries(DateTime.add(DateTime.utc_now(), 2, :hour))

      types =
        Audit.list_events(%{})
        |> Enum.filter(&(&1.queue_entry_id == entry.id))
        |> Enum.map(& &1.type)

      assert "queue_entry.promoted" in types
    end

    test "a promoted entry is then routable" do
      office_fixture()

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(1)
        })

      {:ok, 1} = Queue.promote_due_entries(DateTime.add(DateTime.utc_now(), 2, :hour))

      assert {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))
      assert assigned.status == :assigned
    end

    test "one bad row does not stop the rest" do
      # Each promotion is its own transaction. An entry cancelled between the
      # query and the update must not strand everybody behind it.
      {:ok, a} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(1)
        })

      {:ok, b} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "scheduled_for" => in_hours(1)
        })

      {:ok, _} = Queue.cancel(Queue.get_entry!(a.id))

      assert {:ok, 1} = Queue.promote_due_entries(DateTime.add(DateTime.utc_now(), 2, :hour))
      assert Queue.get_entry!(b.id).status == :waiting
      assert Queue.get_entry!(a.id).status == :cancelled
    end
  end
end
