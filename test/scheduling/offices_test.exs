defmodule Scheduling.OfficesTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices.{Office, OfficeCapability}

  describe "Office.changeset/2" do
    test "requires name and intake_capacity" do
      changeset = Office.changeset(%Office{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
    end

    test "rejects negative intake_capacity" do
      changeset = Office.changeset(%Office{}, %{name: "Room A", intake_capacity: -1})
      refute changeset.valid?

      assert %{intake_capacity: ["must be greater than or equal to 0"]} =
               errors_on(changeset)
    end

    test "is valid with name and non-negative capacity" do
      changeset = Office.changeset(%Office{}, %{name: "Room A", intake_capacity: 3})
      assert changeset.valid?
    end
  end

  describe "office capabilities (many-to-many)" do
    test "an office can be associated with multiple capabilities" do
      {:ok, xray} = Repo.insert(Capability.changeset(%Capability{}, %{name: "XRay"}))
      {:ok, lab} = Repo.insert(Capability.changeset(%Capability{}, %{name: "Lab"}))

      {:ok, office} =
        Repo.insert(Office.changeset(%Office{}, %{name: "Room A", intake_capacity: 2}))

      office
      |> Repo.preload(:capabilities)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:capabilities, [xray, lab])
      |> Repo.update!()

      names =
        office
        |> Repo.preload(:capabilities)
        |> Map.fetch!(:capabilities)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Lab", "XRay"]
    end

    test "OfficeCapability join enforces uniqueness of the pair" do
      {:ok, xray} = Repo.insert(Capability.changeset(%Capability{}, %{name: "XRay"}))

      {:ok, office} =
        Repo.insert(Office.changeset(%Office{}, %{name: "Room B", intake_capacity: 1}))

      attrs = %{office_id: office.id, capability_id: xray.id}
      {:ok, _} = Repo.insert(OfficeCapability.changeset(%OfficeCapability{}, attrs))

      {:error, changeset} =
        Repo.insert(OfficeCapability.changeset(%OfficeCapability{}, attrs))

      assert %{office_id: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
