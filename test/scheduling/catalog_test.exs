defmodule Scheduling.CatalogTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.{Capability, Diagnosis, DiagnosisCapability}

  describe "Capability.changeset/2" do
    test "requires a name" do
      changeset = Capability.changeset(%Capability{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "is valid with a name" do
      changeset = Capability.changeset(%Capability{}, %{name: "XRay"})
      assert changeset.valid?
    end

    test "enforces unique name" do
      {:ok, _} = Repo.insert(Capability.changeset(%Capability{}, %{name: "Lab"}))

      {:error, changeset} =
        Repo.insert(Capability.changeset(%Capability{}, %{name: "Lab"}))

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "Diagnosis.changeset/2" do
    test "requires a name" do
      changeset = Diagnosis.changeset(%Diagnosis{}, %{code: "DX-1"})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique name and code" do
      {:ok, _} =
        Repo.insert(Diagnosis.changeset(%Diagnosis{}, %{name: "Stroke", code: "DX-S"}))

      {:error, changeset} =
        Repo.insert(Diagnosis.changeset(%Diagnosis{}, %{name: "Stroke", code: "DX-X"}))

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "diagnosis default capabilities (BOTH model defaults)" do
    test "a diagnosis maps to a set of default capabilities" do
      {:ok, ct} = Repo.insert(Capability.changeset(%Capability{}, %{name: "CT Scan"}))
      {:ok, lab} = Repo.insert(Capability.changeset(%Capability{}, %{name: "Lab"}))

      {:ok, diagnosis} =
        Repo.insert(Diagnosis.changeset(%Diagnosis{}, %{name: "Stroke Workup"}))

      diagnosis
      |> Repo.preload(:capabilities)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:capabilities, [ct, lab])
      |> Repo.update!()

      names =
        diagnosis
        |> Repo.preload(:capabilities)
        |> Map.fetch!(:capabilities)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["CT Scan", "Lab"]
    end

    test "DiagnosisCapability join requires both ids" do
      changeset = DiagnosisCapability.changeset(%DiagnosisCapability{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.diagnosis_id
      assert "can't be blank" in errors.capability_id
    end
  end
end
