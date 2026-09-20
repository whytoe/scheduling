defmodule SchedulingWeb.OfficeSiteLinkTest do
  @moduledoc """
  Linking an office to a site, through the only surface an operator has.

  `Locations.link_office/2` and the whole per-office access story have been
  shipped and inert: nothing in the application could attach an office to a
  site, so every office was unlinked, and unlinked offices are visible to
  everyone by design. Four pieces of finished work were waiting on this form
  field.
  """
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Locations.Location
  alias Scheduling.Offices
  alias Scheduling.Practices.Practice
  alias Scheduling.Repo

  defp practice_fixture(core_id, name) do
    Repo.insert!(Practice.changeset(%Practice{}, %{core_practice_id: core_id, name: name}))
  end

  defp location_fixture(core_id, name, core_practice_id, opts \\ []) do
    Repo.insert!(
      Location.changeset(%Location{}, %{
        core_location_id: core_id,
        name: name,
        core_practice_id: core_practice_id,
        timezone: Keyword.get(opts, :timezone, "America/New_York"),
        active: Keyword.get(opts, :active, true)
      })
    )
  end

  defp office_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => "2",
        "location_id" => ""
      },
      overrides
    )
  end

  describe "the site picker" do
    test "offers sites by their unambiguous label", %{conn: conn} do
      # Three of production's five sites are called "Main Office". A picker
      # built on `name` would offer three identical options.
      practice_fixture("prac-a", "Avenue D Pediatrics")
      practice_fixture("prac-b", "Sunshine Pediatrics")
      location_fixture("loc-a", "Main Office", "prac-a")
      location_fixture("loc-b", "Main Office", "prac-b")

      {:ok, view, _html} = live(conn, ~p"/offices/new")
      html = render(view)

      assert html =~ "Avenue D Pediatrics — Main Office"
      assert html =~ "Sunshine Pediatrics — Main Office"
    end

    test "offers not-linked, because an unlinked room is legitimate", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/offices/new")
      assert html =~ "Not linked to a site"
    end

    test "does not offer a site ac-core has deactivated", %{conn: conn} do
      practice_fixture("prac-c", "Closed Practice")
      location_fixture("loc-closed", "Shuttered Annex", "prac-c", active: false)

      {:ok, _view, html} = live(conn, ~p"/offices/new")
      refute html =~ "Shuttered Annex"
    end
  end

  describe "creating an office at a site" do
    test "records the link", %{conn: conn} do
      practice_fixture("prac-a", "Avenue D Pediatrics")
      location = location_fixture("loc-a", "Annex", "prac-a")

      {:ok, view, _html} = live(conn, ~p"/offices/new")

      view
      |> form("#office-form", office: office_attrs(%{"location_id" => to_string(location.id)}))
      |> render_submit()

      assert [office] = Offices.list_offices()
      assert office.location_id == location.id
    end

    test "adopts the site timezone, and says so", %{conn: conn} do
      # Slot generation reads Office.timezone, so a silent change moves a
      # room's whole calendar by an hour. An admin who left the field on
      # Etc/UTC and finds it saying something else needs to know why.
      practice_fixture("prac-a", "Avenue D Pediatrics")
      location = location_fixture("loc-a", "Annex", "prac-a", timezone: "America/New_York")

      {:ok, view, _html} = live(conn, ~p"/offices/new")

      html =
        view
        |> form("#office-form", office: office_attrs(%{"location_id" => to_string(location.id)}))
        |> render_submit()

      assert html =~ "adopted America/New_York"
      assert [office] = Offices.list_offices()
      assert office.timezone == "America/New_York"
    end

    test "leaves a deliberately-set timezone alone", %{conn: conn} do
      # The form has no timezone field, so a non-default one was set on
      # purpose — by an import, a migration, or someone at a console.
      # Overriding it would be the mismatch adoption exists to prevent,
      # pointed the other way.
      practice_fixture("prac-a", "Avenue D Pediatrics")
      location = location_fixture("loc-a", "Annex", "prac-a", timezone: "America/New_York")

      {:ok, office} =
        Offices.create_office(%{
          "name" => "Deliberate",
          "intake_capacity" => 1,
          "timezone" => "America/Chicago"
        })

      {:ok, view, _html} = live(conn, ~p"/offices/#{office.id}/edit")

      view
      |> form("#office-form",
        office: %{
          "name" => "Deliberate",
          "intake_capacity" => "1",
          "location_id" => to_string(location.id)
        }
      )
      |> render_submit()

      assert Offices.get_office!(office.id).timezone == "America/Chicago"
    end

    test "an unlinked office keeps its timezone and says nothing extra", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/offices/new")

      html =
        view
        |> form("#office-form", office: office_attrs())
        |> render_submit()

      refute html =~ "adopted"
      assert [office] = Offices.list_offices()
      assert office.location_id == nil
    end
  end

  describe "the link is what makes scoping real" do
    test "a linked office is scoped, an unlinked one is not", %{conn: conn} do
      # The end of the chain this form unblocks: Offices.list_offices/1 filters
      # on the location's core id, which only means anything once an office
      # has one.
      practice_fixture("prac-a", "Avenue D Pediatrics")
      location = location_fixture("loc-a", "Annex", "prac-a")

      {:ok, view, _html} = live(conn, ~p"/offices/new")

      view
      |> form("#office-form",
        office: office_attrs(%{"name" => "Linked", "location_id" => to_string(location.id)})
      )
      |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/offices/new")

      view
      |> form("#office-form", office: office_attrs(%{"name" => "Unlinked"}))
      |> render_submit()

      scoped = Offices.list_offices(location_ids: ["loc-a"]) |> Enum.map(& &1.name) |> Enum.sort()
      elsewhere = Offices.list_offices(location_ids: ["loc-nope"]) |> Enum.map(& &1.name)

      assert scoped == ["Linked", "Unlinked"]
      assert elsewhere == ["Unlinked"]
    end
  end
end
