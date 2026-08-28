defmodule Scheduling.QueueTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Jane Doe", external_id: "ext-1"}))
  end

  describe "Patient.changeset/2" do
    test "requires a name" do
      changeset = Patient.changeset(%Patient{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique external_id" do
      _ = patient_fixture()

      {:error, changeset} =
        Repo.insert(Patient.changeset(%Patient{}, %{name: "John", external_id: "ext-1"}))

      assert %{external_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "QueueEntry.changeset/2" do
    test "requires patient_id" do
      changeset = QueueEntry.changeset(%QueueEntry{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "defaults status to waiting and accepts a patient" do
      patient = patient_fixture()

      {:ok, entry} =
        Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

      assert entry.status == :waiting
      assert entry.priority == 0
    end

    test "rejects an invalid status" do
      patient = patient_fixture()

      changeset =
        QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id, status: :nope})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects negative priority" do
      patient = patient_fixture()

      changeset =
        QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id, priority: -5})

      refute changeset.valid?
      assert %{priority: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end

    test "lists all valid statuses" do
      assert QueueEntry.statuses() == [:waiting, :assigned, :in_service, :completed]
    end
  end

  defp unique(name), do: "#{name}-#{System.unique_integer([:positive])}"

  describe "required capabilities (BOTH model override)" do
    test "an explicit set of required capabilities can be set per entry" do
      patient = patient_fixture()
      # Suffixed: capabilities.name is uniquely indexed and these files run
      # async, so a fixed pair of names deadlocks on the index (40P01).
      {:ok, xray} = Repo.insert(Capability.changeset(%Capability{}, %{name: unique("XRay")}))
      {:ok, mri} = Repo.insert(Capability.changeset(%Capability{}, %{name: unique("MRI")}))

      {:ok, entry} =
        Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

      entry
      |> Repo.preload(:required_capabilities)
      |> QueueEntry.required_capabilities_changeset([xray, mri])
      |> Repo.update!()

      names =
        entry
        |> Repo.preload(:required_capabilities)
        |> Map.fetch!(:required_capabilities)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == Enum.sort([mri.name, xray.name])
    end

    test "setting required capabilities replaces the previous set" do
      patient = patient_fixture()
      {:ok, xray} = Repo.insert(Capability.changeset(%Capability{}, %{name: "XRay"}))
      {:ok, lab} = Repo.insert(Capability.changeset(%Capability{}, %{name: "Lab"}))

      {:ok, entry} =
        Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

      entry = Repo.preload(entry, :required_capabilities)

      entry
      |> QueueEntry.required_capabilities_changeset([xray])
      |> Repo.update!()

      reloaded = Repo.preload(entry, :required_capabilities, force: true)

      reloaded
      |> QueueEntry.required_capabilities_changeset([lab])
      |> Repo.update!()

      names =
        entry
        |> Repo.preload(:required_capabilities, force: true)
        |> Map.fetch!(:required_capabilities)
        |> Enum.map(& &1.name)

      assert names == ["Lab"]
    end
  end
end
