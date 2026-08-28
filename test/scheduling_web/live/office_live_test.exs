defmodule SchedulingWeb.OfficeLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Offices
  alias Scheduling.Repo
  alias Scheduling.Catalog.Capability

  # Names are suffixed because `capabilities.name` is uniquely indexed and these
  # test files run async. Two tests inserting "MRI" and "XRay" in opposite
  # orders each wait on the other's index lock — a genuine Postgres deadlock
  # (40P01), and the source of a long-running intermittent CI failure.
  defp capability_fixture(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"
    Repo.insert!(Capability.changeset(%Capability{}, %{name: unique}))
  end

  defp office_fixture(attrs) do
    {:ok, office} = Offices.create_office(attrs)
    office
  end

  describe "Index" do
    test "lists offices with their capabilities", %{conn: conn} do
      xray = capability_fixture("XRay")
      office_fixture(%{"name" => "Room A", "intake_capacity" => 3, "capability_ids" => [xray.id]})

      {:ok, _live, html} = live(conn, ~p"/offices")

      assert html =~ "Offices"
      assert html =~ "Room A"
      assert html =~ "XRay"
    end
  end

  describe "create office" do
    test "creates an office with a capability", %{conn: conn} do
      xray = capability_fixture("XRay")

      {:ok, live, _html} = live(conn, ~p"/offices/new")

      html =
        live
        |> form("#office-form",
          office: %{name: "Room B", intake_capacity: "5", capability_ids: ["#{xray.id}"]}
        )
        |> render_submit()

      # push_patch back to index, then the stream reflects the new office.
      assert_patched(live, ~p"/offices")
      assert render(live) =~ "Room B"
      assert render(live) =~ "XRay"
      refute html == ""

      assert [office] = Offices.list_offices()
      assert office.name == "Room B"
      assert office.intake_capacity == 5
      assert Enum.map(office.capabilities, & &1.name) == [xray.name]
    end

    test "shows validation errors for invalid input", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/offices/new")

      html =
        live
        |> form("#office-form", office: %{name: "", intake_capacity: "-1"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert html =~ "must be greater than or equal to 0"
      assert Offices.list_offices() == []
    end
  end

  describe "edit office: add and remove capabilities" do
    test "adds a capability to an existing office", %{conn: conn} do
      xray = capability_fixture("XRay")
      lab = capability_fixture("Lab")

      office =
        office_fixture(%{
          "name" => "Room C",
          "intake_capacity" => 2,
          "capability_ids" => [xray.id]
        })

      {:ok, live, _html} = live(conn, ~p"/offices/#{office}/edit")

      live
      |> form("#office-form",
        office: %{
          name: "Room C",
          intake_capacity: "2",
          capability_ids: ["#{xray.id}", "#{lab.id}"]
        }
      )
      |> render_submit()

      assert_patched(live, ~p"/offices")

      reloaded = Offices.get_office!(office.id)
      names = reloaded.capabilities |> Enum.map(& &1.name) |> Enum.sort()
      assert names == Enum.sort([lab.name, xray.name])
    end

    test "removes all capabilities from an office", %{conn: conn} do
      xray = capability_fixture("XRay")

      office =
        office_fixture(%{
          "name" => "Room D",
          "intake_capacity" => 1,
          "capability_ids" => [xray.id]
        })

      {:ok, live, _html} = live(conn, ~p"/offices/#{office}/edit")

      live
      |> form("#office-form",
        office: %{name: "Room D", intake_capacity: "1", capability_ids: [""]}
      )
      |> render_submit()

      assert_patched(live, ~p"/offices")

      reloaded = Offices.get_office!(office.id)
      assert reloaded.capabilities == []
    end
  end

  describe "delete office" do
    test "deletes an office from the list", %{conn: conn} do
      _office = office_fixture(%{"name" => "Room E", "intake_capacity" => 1})

      {:ok, live, _html} = live(conn, ~p"/offices")

      assert render(live) =~ "Room E"

      # Delete opens a confirmation dialog naming the consequence; confirm it.
      live |> element("button[aria-label='Delete Room E']") |> render_click()
      assert render(live) =~ "will be removed"

      live |> element("#delete-office button", "Delete office") |> render_click()

      refute has_element?(live, "#offices", "Room E")
      assert Offices.list_offices() == []
    end
  end
end
