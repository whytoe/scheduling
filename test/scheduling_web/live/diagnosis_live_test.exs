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
      diagnosis_fixture(%{"name" => "Chest pain", "code" => "R07.9", "required_form_types" => ["cardiac-history"]})

      {:ok, _live, html} = live(conn, ~p"/diagnoses")

      assert html =~ "Diagnoses"
      assert html =~ "Chest pain"
      assert html =~ "R07.9"
      assert html =~ "cardiac-history"
    end

    test "shows an empty state with no diagnoses", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/diagnoses")
      assert html =~ "No diagnoses yet"
    end
  end

  describe "new diagnosis" do
    test "flags a sensitive form type as the operator types and on add", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/diagnoses/new")

      html =
        live
        |> form(~s|form[phx-submit="add_form"]|, %{draft: "phq-9"})
        |> render_change()

      assert html =~ "looks like a sensitive form type"

      html =
        live
        |> form(~s|form[phx-submit="add_form"]|, %{draft: "phq-9"})
        |> render_submit()

      # Selected sensitive chip + the summary info callout.
      assert html =~ "phq-9"
      assert html =~ "sensitive form type"
    end

    test "creates a diagnosis carrying the added form types", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/diagnoses/new")

      live |> form(~s|form[phx-submit="add_form"]|, %{draft: "gad-7"}) |> render_submit()

      live
      |> form("#diagnosis-form", diagnosis: %{name: "Counselling intake", code: "Z71.9"})
      |> render_submit()

      assert_patched(live, ~p"/diagnoses")

      dx = Catalog.list_diagnoses() |> Enum.find(&(&1.name == "Counselling intake"))
      assert dx
      assert "gad-7" in dx.required_form_types
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
