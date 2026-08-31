defmodule SchedulingWeb.DiagnosisLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Catalog

  defp diagnosis_fixture(attrs) do
    {:ok, dx} = Catalog.create_diagnosis(attrs)
    dx
  end

  describe "Index" do
    test "lists diagnoses with their form types", %{conn: conn} do
      diagnosis_fixture(%{
        "name" => "Chest pain",
        "code" => "R07.9",
        "required_compliance_refs" => ["cref_0b2e5d9a1c74"]
      })

      {:ok, _live, html} = live(conn, ~p"/diagnoses")

      assert html =~ "Diagnoses"
      assert html =~ "Chest pain"
      assert html =~ "R07.9"
      assert html =~ "cref_0b2e5d9a1c74"
    end

    test "shows an empty state with no diagnoses", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/diagnoses")
      assert html =~ "No diagnoses yet"
    end
  end

  describe "new diagnosis" do
    # The catalog holds opaque references from intakeform, not form names. A
    # form name typed here is clinical content, which this system does not
    # carry — so the warning fires on anything that is not reference-shaped
    # rather than on a hardcoded list of sensitive names. That inversion is
    # what lets it catch names nobody thought to list.
    test "flags a value that is not a compliance reference, as typed and on add",
         %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/diagnoses/new")

      html =
        live
        |> form(~s|form[phx-submit="add_form"]|, %{draft: "phq-9"})
        |> render_change()

      assert html =~ "is not a compliance reference"

      html =
        live
        |> form(~s|form[phx-submit="add_form"]|, %{draft: "phq-9"})
        |> render_submit()

      assert html =~ "phq-9"
      assert html =~ "not a compliance reference"
    end

    test "does not flag a well-formed reference", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/diagnoses/new")

      html =
        live
        |> form(~s|form[phx-submit="add_form"]|, %{draft: "cref_7f3a91c4e2b8"})
        |> render_change()

      refute html =~ "is not a compliance reference"
    end

    test "creates a diagnosis carrying the added form types", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/diagnoses/new")

      live
      |> form(~s|form[phx-submit="add_form"]|, %{draft: "cref_9d41ab77e0c2"})
      |> render_submit()

      live
      |> form("#diagnosis-form", diagnosis: %{name: "Counselling intake", code: "Z71.9"})
      |> render_submit()

      assert_patched(live, ~p"/diagnoses")

      dx = Catalog.list_diagnoses() |> Enum.find(&(&1.name == "Counselling intake"))
      assert dx
      assert "cref_9d41ab77e0c2" in dx.required_compliance_refs
    end
  end

  describe "delete" do
    test "deletes a diagnosis after confirmation", %{conn: conn} do
      diagnosis_fixture(%{"name" => "Wrist injury", "code" => "S62.5"})

      {:ok, live, _html} = live(conn, ~p"/diagnoses")

      live |> element("button[aria-label='Delete Wrist injury']") |> render_click()
      assert render(live) =~ "cannot be undone"

      live |> element("#delete-diagnosis button", "Delete diagnosis") |> render_click()

      assert Catalog.list_diagnoses() == []
    end
  end
end
