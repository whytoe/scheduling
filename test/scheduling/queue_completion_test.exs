defmodule Scheduling.QueueCompletionTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Matching.Result
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  defp capability_fixture(name) do
    Repo.insert!(Capability.changeset(%Capability{}, %{name: name}))
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
      Repo.insert(
        QueueEntry.changeset(%QueueEntry{}, %{
          patient_id: patient.id,
          priority: Keyword.get(opts, :priority, 0)
        })
      )

    entry
    |> Repo.preload(:required_capabilities)
    |> QueueEntry.required_capabilities_changeset(required_caps)
    |> Repo.update!()
  end

  defp accept!(entry) do
    {:ok, assigned, _result} = Queue.accept(entry)
    assigned
  end

  describe "complete/1 — frees capacity" do
    test "transitions assigned -> completed and releases the office's slot" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      assert Queue.current_loads() == %{office.id => 1}

      assert {:ok, completed} = Queue.complete(assigned)
      assert completed.status == :completed

      # The slot is freed: the office's derived load drops back to zero.
      assert Queue.current_loads() == %{}

      reloaded = Repo.get!(QueueEntry, assigned.id)
      assert reloaded.status == :completed
    end

    test "completes an in-service entry" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])

      assigned = accept!(waiting_entry([xray]))
      in_service = assigned |> Ecto.Changeset.change(status: :in_service) |> Repo.update!()

      assert {:ok, completed} = Queue.complete(in_service)
      assert completed.status == :completed
      assert Queue.current_loads() == %{}
    end

    test "the matcher can place a patient once a full office completes service" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Single Room", 1, [xray.id])

      first = accept!(waiting_entry([xray], patient_name: "First"))

      # Office is full: the next patient cannot be placed.
      assert {:no_eligible_office, %Result{}} =
               Queue.accept(waiting_entry([xray], patient_name: "Second"))

      # Completing the first patient frees the slot for the matcher.
      {:ok, _completed} = Queue.complete(first)

      assert {:ok, assigned, %Result{}} =
               Queue.accept(waiting_entry([xray], patient_name: "Third"))

      assert assigned.status == :assigned
    end

    test "broadcasts a board change so live boards update" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])
      assigned = accept!(waiting_entry([xray]))

      Queue.subscribe_board()
      {:ok, completed} = Queue.complete(assigned)

      assert_receive {:board_changed, {:completed, id}}
      assert id == completed.id
    end

    test "rejects completing a waiting entry" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])
      entry = waiting_entry([xray])

      assert {:error, changeset} = Queue.complete(entry)
      assert "must be assigned or in service, was waiting" in errors_on(changeset).status
    end

    test "rejects completing an already-completed entry" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])
      assigned = accept!(waiting_entry([xray]))
      {:ok, completed} = Queue.complete(assigned)

      assert {:error, changeset} = Queue.complete(completed)
      assert "must be assigned or in service, was completed" in errors_on(changeset).status
    end
  end

  describe "requeue/2 — multi-service visit" do
    test "returns the patient to waiting with new requirements and frees the slot" do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")
      office = office_fixture("Room A", 2, [xray.id, lab.id])

      assigned = accept!(waiting_entry([xray]))
      assert Queue.current_loads() == %{office.id => 1}

      assert {:ok, requeued} = Queue.requeue(assigned, [lab])
      assert requeued.status == :waiting
      assert is_nil(requeued.assigned_office_id)
      assert Enum.map(requeued.required_capabilities, & &1.name) == ["Lab"]

      # The slot is freed and the patient is back in the waiting list.
      assert Queue.current_loads() == %{}
      waiting_ids = Enum.map(Queue.list_waiting_entries(), & &1.id)
      assert assigned.id in waiting_ids
    end

    test "a re-queued patient can be accepted again for the new service" do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")
      _office = office_fixture("Room A", 2, [xray.id, lab.id])

      assigned = accept!(waiting_entry([xray]))
      {:ok, requeued} = Queue.requeue(assigned, [lab])

      reloaded = Queue.get_entry!(requeued.id)
      assert {:ok, reassigned, %Result{}} = Queue.accept(reloaded)
      assert reassigned.status == :assigned
    end

    test "broadcasts a board change" do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")
      _office = office_fixture("Room A", 2, [xray.id, lab.id])
      assigned = accept!(waiting_entry([xray]))

      Queue.subscribe_board()
      {:ok, requeued} = Queue.requeue(assigned, [lab])

      assert_receive {:board_changed, {:requeued, id}}
      assert id == requeued.id
    end

    test "rejects re-queuing a waiting entry" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])
      entry = waiting_entry([xray])

      assert {:error, changeset} = Queue.requeue(entry, [])
      assert "must be assigned or in service, was waiting" in errors_on(changeset).status
    end
  end

  describe "list_active_entries/0" do
    test "lists only entries occupying capacity, with associations preloaded" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 5, [xray.id])

      assigned = accept!(waiting_entry([xray], patient_name: "Active"))
      _waiting = waiting_entry([xray], patient_name: "Still Waiting")
      done = accept!(waiting_entry([xray], patient_name: "Done"))
      {:ok, _completed} = Queue.complete(done)

      active = Queue.list_active_entries()

      assert Enum.map(active, & &1.id) == [assigned.id]
      [entry] = active
      assert entry.patient.name == "Active"
      assert entry.assigned_office.name == "Room A"
    end
  end
end
