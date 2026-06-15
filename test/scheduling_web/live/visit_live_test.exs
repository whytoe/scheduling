defmodule SchedulingWeb.VisitLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Patients.Patient
  alias Scheduling.Repo
  alias Scheduling.Visits

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  defp visit_fixture(name) do
    patient = patient_fixture(name)

    {:ok, visit} =
      Visits.create_visit(%{
        patient_id: patient.id,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    visit
  end

  describe "Index" do
    test "renders a skeleton table on the static first paint", %{conn: conn} do
      html = conn |> get(~p"/visits") |> html_response(200)
      assert html =~ "skel"
    end

    test "lists visits once connected", %{conn: conn} do
      visit = visit_fixture("Marcus Bauer")

      {:ok, _live, html} = live(conn, ~p"/visits")

      assert html =~ "Visits"
      assert html =~ "Marcus Bauer"
      assert html =~ "v-#{visit.id}"
    end

    test "expands a row to the lifecycle timeline", %{conn: conn} do
      visit_fixture("Marcus Bauer")

      {:ok, live, _html} = live(conn, ~p"/visits")

      html = live |> element("tr", "Marcus Bauer") |> render_click()
      # create_visit recorded a visit.created event -> "Visit opened" in the timeline.
      assert html =~ "Visit opened"
    end

    test "shows an empty state when there are no visits", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/visits")
      assert html =~ "No visits yet"
    end
  end
end
