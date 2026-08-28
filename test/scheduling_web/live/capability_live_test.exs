defmodule SchedulingWeb.CapabilityLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Catalog

  defp capability_fixture(name) do
    {:ok, cap} = Catalog.create_capability(%{"name" => name})
    cap
  end

  describe "Index" do
    test "lists capabilities as a card grid", %{conn: conn} do
      capability_fixture("Audiology")

      {:ok, _live, html} = live(conn, ~p"/capabilities")

      assert html =~ "Capabilities"
      assert html =~ "Audiology"
      assert html =~ "grid-cards"
    end

    test "filters by search", %{conn: conn} do
      capability_fixture("Audiology")
      capability_fixture("Phlebotomy")

      {:ok, live, _html} = live(conn, ~p"/capabilities")

      html = live |> form("form[phx-change=search]", %{q: "audio"}) |> render_change()
      assert html =~ "Audiology"
      refute html =~ "Phlebotomy"
    end
  end

  describe "new / edit" do
    test "creates a capability via the inline form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/capabilities/new")

      html =
        live
        |> form("#capability-form", capability: %{name: "Dialysis"})
        |> render_submit()

      assert_patched(live, ~p"/capabilities")
      assert render(live) =~ "Dialysis"
      assert html =~ "Dialysis" or render(live) =~ "Dialysis"
    end
  end

  describe "delete" do
    test "deletes a capability after confirmation", %{conn: conn} do
      capability_fixture("Audiology")

      {:ok, live, _html} = live(conn, ~p"/capabilities")

      live |> element("button[aria-label='Delete Audiology']") |> render_click()
      assert render(live) =~ "will be removed"

      live |> element("#delete-capability button", "Delete capability") |> render_click()

      refute has_element?(live, ".grid-cards", "Audiology")
      assert Catalog.list_capabilities() == []
    end
  end
end
