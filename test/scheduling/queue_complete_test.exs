defmodule Scheduling.QueueCompleteTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  # Names are suffixed because `capabilities.name` is uniquely indexed and these
  # test files run async. Two tests inserting "MRI" and "XRay" in opposite
  # orders each wait on the other's index lock — a genuine Postgres deadlock
  # (40P01), and the source of a long-running intermittent CI failure.
  defp capability_fixture(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"
    Repo.insert!(Capability.changeset(%Capability{}, %{name: unique}))
  end

  defp office_fixture(name, capacity, capability_ids) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => name,
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    office
  end

  defp waiting_entry(required_caps, opts \\ []) do
    patient = patient_fixture(Keyword.get(opts, :patient_name, "Jane Doe"))

    {:ok, entry} =
      Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

    entry
    |> Repo.preload(:required_capabilities)
    |> QueueEntry.required_capabilities_changeset(required_caps)
    |> Repo.update!()
  end

  defp accept!(entry) do
    {:ok, assigned, _result} = Queue.accept(entry)
    assigned
  end

  describe "complete/1" do
    test "transitions an assigned entry to completed" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      assert assigned.status == :assigned

      assert {:ok, completed} = Queue.complete(assigned)
      assert completed.status == :completed

      reloaded = Repo.get!(QueueEntry, assigned.id)
      assert reloaded.status == :completed
    end

    test "frees the office capacity so the matcher sees the slot return" do
      xray = capability_fixture("XRay")
      office = office_fixture("Single Room", 1, [xray.id])

      assigned = accept!(waiting_entry([xray], patient_name: "First"))
      assert Queue.current_loads() == %{office.id => 1}

      # At capacity: the next patient cannot be placed.
      second = waiting_entry([xray], patient_name: "Second")
      assert {:no_eligible_office, _} = Queue.accept(second)

      # Completing the first frees the slot for the matcher.
      assert {:ok, _completed} = Queue.complete(assigned)
      assert Queue.current_loads() == %{}

      assert {:ok, assigned_second, _} = Queue.accept(Queue.get_entry!(second.id))
      assert assigned_second.assigned_office_id == office.id
    end

    test "retains the assigned office on the completed entry as a record" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      assert {:ok, completed} = Queue.complete(assigned)

      assert completed.assigned_office_id == office.id
    end

    test "broadcasts a capacity change on the board topic" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))

      Queue.subscribe_board()
      assert {:ok, completed} = Queue.complete(assigned)
      assert_receive {:board_changed, {:completed, id}}
      assert id == completed.id
    end

    test "rejects completing an entry that is not in service" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      {:ok, _completed} = Queue.complete(assigned)

      # Completing an already-completed entry is rejected.
      stale = Repo.get!(QueueEntry, assigned.id)
      assert {:error, changeset} = Queue.complete(stale)

      assert "must be assigned or in_service to complete, was completed" in errors_on(changeset).status
    end
  end

  describe "requeue/2" do
    test "returns an in-progress entry to the waiting queue and frees capacity" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      assert Queue.current_loads() == %{office.id => 1}

      assert {:ok, requeued} = Queue.requeue(assigned)
      assert requeued.status == :waiting
      assert is_nil(requeued.assigned_office_id)
      assert Queue.current_loads() == %{}

      waiting_ids = Enum.map(Queue.list_waiting_entries(), & &1.id)
      assert assigned.id in waiting_ids
    end

    test "replaces required capabilities with the new service's requirements" do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      _office = office_fixture("Room A", 2, [xray.id, mri.id])

      assigned = accept!(waiting_entry([xray]))

      assert {:ok, requeued} = Queue.requeue(assigned, required_capabilities: [mri])

      names = requeued.required_capabilities |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [mri.name]
    end

    test "re-routes to a different best-fit office after re-queue with new needs" do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")

      _xray_room = office_fixture("XRay Room", 2, [xray.id])
      mri_room = office_fixture("MRI Room", 2, [mri.id])

      assigned = accept!(waiting_entry([xray]))
      assert assigned.assigned_office.name == "XRay Room"

      {:ok, _requeued} = Queue.requeue(assigned, required_capabilities: [mri])

      assert {:ok, rerouted, _result} = Queue.accept(Queue.get_entry!(assigned.id))
      assert rerouted.assigned_office_id == mri_room.id
    end

    test "broadcasts a capacity change on the board topic" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))

      Queue.subscribe_board()
      assert {:ok, requeued} = Queue.requeue(assigned)
      assert_receive {:board_changed, {:requeued, id}}
      assert id == requeued.id
    end

    test "rejects re-queuing an entry that is not in service" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      entry = waiting_entry([xray])
      assert {:error, changeset} = Queue.requeue(entry)

      assert "must be assigned or in_service to re-queue, was waiting" in errors_on(changeset).status
    end
  end

  describe "list_active_entries/0" do
    test "returns only entries occupying capacity, with associations preloaded" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 5, [xray.id])

      assigned = accept!(waiting_entry([xray], patient_name: "Active"))
      _waiting = waiting_entry([xray], patient_name: "Still Waiting")

      done = accept!(waiting_entry([xray], patient_name: "Done"))
      {:ok, _} = Queue.complete(done)

      active = Queue.list_active_entries()

      ids = Enum.map(active, & &1.id)
      assert assigned.id in ids
      refute done.id in ids

      entry = Enum.find(active, &(&1.id == assigned.id))
      assert entry.patient.name == "Active"
      assert entry.assigned_office.name == "Room A"
    end
  end
end
