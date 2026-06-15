defmodule SchedulingWeb.VisitEventLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Audit
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  describe "Index" do
    test "shows an empty state when there are no events", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/visit_events")
      assert html =~ "Visit events"
      assert html =~ "No visit events yet"
    end

    test "groups events by visit and expands to a timeline with actors", %{conn: conn} do
      patient = patient_fixture("Grace Mbeki")

      {:ok, _} =
        Audit.record_event(%{
          type: "queue_entry.created",
          patient_id: patient.id,
          actor_type: "front_desk"
        })

      {:ok, _} =
        Audit.record_event(%{
          type: "queue_entry.completed",
          patient_id: patient.id,
          actor_type: "clinical"
        })

      {:ok, live, html} = live(conn, ~p"/visit_events")

      assert html =~ "Grace Mbeki"
      # Collapsed: the group shows a derived status badge.
      assert html =~ "Completed"

      # Expand to reveal the timeline + event labels + actor attribution.
      html = live |> element(".audit__row", "Grace Mbeki") |> render_click()
      assert html =~ "Signed in"
      assert html =~ "Front desk"
      assert html =~ "Clinician"
    end
  end
end
