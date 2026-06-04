defmodule Scheduling.OfficesContextTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Catalog.Capability

  defp capability_fixture(name) do
    Repo.insert!(Capability.changeset(%Capability{}, %{name: name}))
  end

  describe "list_offices/0 and get_office!/1" do
    test "returns offices with capabilities preloaded" do
      xray = capability_fixture("XRay")

      {:ok, office} =
        Offices.create_office(%{
          "name" => "Room A",
          "intake_capacity" => 2,
          "capability_ids" => [xray.id]
        })

      assert [listed] = Offices.list_offices()
      assert listed.id == office.id
      assert Enum.map(listed.capabilities, & &1.name) == ["XRay"]

      fetched = Offices.get_office!(office.id)
      assert fetched.name == "Room A"
      assert Enum.map(fetched.capabilities, & &1.name) == ["XRay"]
    end
  end

  describe "create_office/1" do
    test "creates an office without capabilities" do
      assert {:ok, office} = Offices.create_office(%{"name" => "Room A", "intake_capacity" => 3})
      assert office.name == "Room A"
      assert office.intake_capacity == 3
      assert office.capabilities == []
    end

    test "creates an office with multiple capabilities" do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")

      assert {:ok, office} =
               Offices.create_office(%{
                 "name" => "Room B",
                 "intake_capacity" => 1,
                 "capability_ids" => [xray.id, lab.id]
               })

      names = office.capabilities |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Lab", "XRay"]
    end

    test "rejects missing name" do
      assert {:error, changeset} = Offices.create_office(%{"intake_capacity" => 1})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects negative capacity" do
      assert {:error, changeset} =
               Offices.create_office(%{"name" => "Room", "intake_capacity" => -1})

      assert %{intake_capacity: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end
  end

  describe "update_office/2 capability management" do
    test "replaces the office's capabilities" do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")

      {:ok, office} =
        Offices.create_office(%{
          "name" => "Room C",
          "intake_capacity" => 2,
          "capability_ids" => [xray.id]
        })

      {:ok, updated} = Offices.update_office(office, %{"capability_ids" => [lab.id]})
      assert Enum.map(updated.capabilities, & &1.name) == ["Lab"]
    end

    test "clears all capabilities with an empty list" do
      xray = capability_fixture("XRay")

      {:ok, office} =
        Offices.create_office(%{
          "name" => "Room D",
          "intake_capacity" => 1,
          "capability_ids" => [xray.id]
        })

      {:ok, updated} = Offices.update_office(office, %{"capability_ids" => []})
      assert updated.capabilities == []
    end

    test "leaves capabilities untouched when capability_ids absent" do
      xray = capability_fixture("XRay")

      {:ok, office} =
        Offices.create_office(%{
          "name" => "Room E",
          "intake_capacity" => 1,
          "capability_ids" => [xray.id]
        })

      {:ok, updated} = Offices.update_office(office, %{"intake_capacity" => 4})
      assert updated.intake_capacity == 4
      assert Enum.map(updated.capabilities, & &1.name) == ["XRay"]
    end
  end

  describe "delete_office/1" do
    test "deletes the office" do
      {:ok, office} = Offices.create_office(%{"name" => "Room F", "intake_capacity" => 1})
      assert {:ok, _} = Offices.delete_office(office)
      assert Offices.list_offices() == []
    end
  end

  describe "list_capabilities/0" do
    test "returns the catalog ordered by name" do
      capability_fixture("XRay")
      capability_fixture("CT Scan")
      capability_fixture("Lab")

      assert Catalog.list_capabilities() |> Enum.map(& &1.name) == ["CT Scan", "Lab", "XRay"]
    end
  end
end
