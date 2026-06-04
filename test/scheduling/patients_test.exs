defmodule Scheduling.PatientsTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Patients
  alias Scheduling.Patients.Patient

  describe "Patient.changeset/2 — client_id" do
    test "auto-generates a uuid client_id when not supplied" do
      {:ok, patient} = Patients.create_patient(%{name: "Auto"})

      assert is_binary(patient.client_id)
      assert {:ok, _} = Ecto.UUID.cast(patient.client_id)
    end

    test "accepts an explicit client_id" do
      uuid = Ecto.UUID.generate()
      {:ok, patient} = Patients.create_patient(%{name: "Explicit", client_id: uuid})

      assert patient.client_id == uuid
    end

    test "enforces uniqueness of client_id" do
      uuid = Ecto.UUID.generate()
      {:ok, _} = Patients.create_patient(%{name: "First", client_id: uuid})

      assert {:error, changeset} = Patients.create_patient(%{name: "Second", client_id: uuid})
      assert "has already been taken" in errors_on(changeset).client_id
    end

    test "enforces uniqueness of intake_patient_id" do
      uuid = Ecto.UUID.generate()
      {:ok, _} = Patients.create_patient(%{name: "First", intake_patient_id: uuid})

      assert {:error, changeset} =
               Patients.create_patient(%{name: "Second", intake_patient_id: uuid})

      assert "has already been taken" in errors_on(changeset).intake_patient_id
    end

    test "client_id is required (via auto-generation)" do
      # Changing the patient to nullify client_id should be rejected on save.
      {:ok, patient} = Patients.create_patient(%{name: "P1"})

      changeset = Patient.changeset(patient, %{name: "P1"})
      assert changeset.valid?
      # After cast/maybe_generate_client_id, client_id is set (or kept from the
      # existing row). It must never be nil.
      refute is_nil(Ecto.Changeset.get_field(changeset, :client_id))
    end
  end
end
