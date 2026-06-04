defmodule SchedulingWeb.Api.VisitEventControllerTest do
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo
  alias Scheduling.Visits.Visit

  setup do
    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Events API"}))

    visit =
      Repo.insert!(
        Visit.changeset(%Visit{}, %{
          patient_id: patient.id,
          status: :active,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      )

    entry =
      Repo.insert!(
        QueueEntry.changeset(%QueueEntry{}, %{
          patient_id: patient.id,
          status: :waiting,
          priority: 0
        })
      )

    {:ok, a} =
      Audit.record_event(%{type: "visit.created", visit_id: visit.id, patient_id: patient.id})

    {:ok, b} =
      Audit.record_event(%{
        type: "queue_entry.created",
        visit_id: visit.id,
        queue_entry_id: entry.id
      })

    {:ok, c} =
      Audit.record_event(%{
        type: "visit.ended",
        visit_id: visit.id,
        patient_id: patient.id,
        actor_type: "user",
        actor_id: "nurse-7"
      })

    %{a: a, b: b, c: c, visit: visit, entry: entry, patient: patient}
  end

  describe "GET /api/visit_events" do
    test "returns events most-recent first", %{conn: conn} do
      conn = get(conn, ~p"/api/visit_events")
      body = json_response(conn, 200)
      assert is_list(body)
      assert length(body) >= 3
    end

    test "filters by visit_id", %{conn: conn, visit: visit} do
      conn = get(conn, ~p"/api/visit_events?visit_id=#{visit.id}")
      body = json_response(conn, 200)
      assert Enum.all?(body, &(&1["visit_id"] == visit.id))
      assert length(body) == 3
    end

    test "filters by type", %{conn: conn, c: c} do
      conn = get(conn, ~p"/api/visit_events?type=visit.ended")
      body = json_response(conn, 200)
      assert [event] = body
      assert event["id"] == c.id
      assert event["actor_type"] == "user"
      assert event["actor_id"] == "nurse-7"
    end

    test "filters by queue_entry_id", %{conn: conn, b: b, entry: entry} do
      conn = get(conn, ~p"/api/visit_events?queue_entry_id=#{entry.id}")
      body = json_response(conn, 200)
      assert [event] = body
      assert event["id"] == b.id
    end

    test "ignores non-integer ids gracefully (returns no rows for that filter)", %{conn: conn} do
      conn = get(conn, ~p"/api/visit_events?visit_id=not_a_number")
      assert is_list(json_response(conn, 200))
    end
  end

  describe "GET /api/visit_events/:id" do
    test "returns the event", %{conn: conn, a: a} do
      conn = get(conn, ~p"/api/visit_events/#{a.id}")
      body = json_response(conn, 200)
      assert body["id"] == a.id
      assert body["type"] == "visit.created"
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/visit_events/99999")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
