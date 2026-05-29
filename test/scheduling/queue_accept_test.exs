defmodule Scheduling.QueueAcceptTest do
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

  describe "accept/1 — successful assignment" do
    test "assigns the patient to the best-fit eligible office" do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      lab = capability_fixture("Lab")

      tight = office_fixture("Tight Room", 2, [xray.id])
      _loose = office_fixture("Loose Room", 2, [xray.id, mri.id, lab.id])

      entry = waiting_entry([xray])

      assert {:ok, assigned, %Result{} = result} = Queue.accept(entry)
      assert assigned.status == :assigned
      assert assigned.assigned_office_id == tight.id
      assert assigned.assigned_office.name == "Tight Room"
      assert result.rationale =~ "Tight Room"
    end

    test "increments the chosen office's current load" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 3, [xray.id])

      assert Queue.current_loads() == %{}

      {:ok, _assigned, _result} = Queue.accept(waiting_entry([xray]))

      assert Queue.current_loads() == %{office.id => 1}
    end

    test "transitions status waiting -> assigned and persists it" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 1, [xray.id])

      entry = waiting_entry([xray])
      assert entry.status == :waiting

      {:ok, assigned, _result} = Queue.accept(entry)

      reloaded = Repo.get!(QueueEntry, assigned.id)
      assert reloaded.status == :assigned
      refute is_nil(reloaded.assigned_office_id)
    end
  end

  describe "accept/1 — no eligible office" do
    test "leaves the patient waiting when no office provides the capabilities" do
      capability_fixture("XRay") |> then(&office_fixture("XRay Room", 2, [&1.id]))
      mri = capability_fixture("MRI")

      entry = waiting_entry([mri])

      assert {:no_eligible_office, %Result{chosen: nil} = result} = Queue.accept(entry)
      assert result.rationale =~ "No eligible office"

      reloaded = Repo.get!(QueueEntry, entry.id)
      assert reloaded.status == :waiting
      assert is_nil(reloaded.assigned_office_id)
    end

    test "treats a full office as ineligible (capacity reflected)" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Single Room", 1, [xray.id])

      {:ok, _first, _} = Queue.accept(waiting_entry([xray], patient_name: "First"))

      # Office is now at capacity; the second waiting patient cannot be placed.
      assert {:no_eligible_office, %Result{}} =
               Queue.accept(waiting_entry([xray], patient_name: "Second"))
    end
  end

  describe "list_waiting_entries/0" do
    test "returns only waiting entries, highest priority first" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 5, [xray.id])

      _low = waiting_entry([xray], patient_name: "Low", priority: 1)
      high = waiting_entry([xray], patient_name: "High", priority: 9)

      {:ok, _assigned, _} = Queue.accept(waiting_entry([xray], patient_name: "Done"))

      waiting = Queue.list_waiting_entries()

      names = Enum.map(waiting, & &1.patient.name)
      assert names == ["High", "Low"]
      assert hd(waiting).id == high.id
      refute "Done" in names
    end
  end

  describe "QueueEntry.assignment_changeset/2" do
    test "rejects assigning an entry that is not waiting" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 1, [xray.id])

      entry = waiting_entry([xray])
      {:ok, assigned, _} = Queue.accept(entry)

      changeset = QueueEntry.assignment_changeset(assigned, office)
      refute changeset.valid?
      assert "must be waiting to assign, was assigned" in errors_on(changeset).status
    end
  end
end
