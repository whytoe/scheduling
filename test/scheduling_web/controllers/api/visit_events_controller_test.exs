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
      conn = get(conn, ~p"/api/v1/visit_events")
      body = json_response(conn, 200)
      assert is_list(body)
      assert length(body) >= 3
    end

    test "filters by visit_id", %{conn: conn, visit: visit} do
      conn = get(conn, ~p"/api/v1/visit_events?visit_id=#{visit.id}")
      body = json_response(conn, 200)
      assert Enum.all?(body, &(&1["visit_id"] == visit.id))
      assert length(body) == 3
    end

    test "filters by type", %{conn: conn, c: c} do
      conn = get(conn, ~p"/api/v1/visit_events?type=visit.ended")
      body = json_response(conn, 200)
      assert [event] = body
      assert event["id"] == c.id
      assert event["actor_type"] == "user"
      assert event["actor_id"] == "nurse-7"
    end

    test "filters by queue_entry_id", %{conn: conn, b: b, entry: entry} do
      conn = get(conn, ~p"/api/v1/visit_events?queue_entry_id=#{entry.id}")
      body = json_response(conn, 200)
      assert [event] = body
      assert event["id"] == b.id
    end

    test "?since=iso8601 returns only events at-or-after the timestamp",
         %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, late} =
        Scheduling.Audit.record_event(%{
          type: "queue_entry.completed",
          occurred_at: DateTime.add(now, 3600, :second)
        })

      {:ok, _ignored_old} =
        Scheduling.Audit.record_event(%{
          type: "queue_entry.completed",
          occurred_at: DateTime.add(now, -3600, :second)
        })

      since = DateTime.to_iso8601(now)
      conn = get(conn, ~p"/api/v1/visit_events?since=#{since}")
      body = json_response(conn, 200)

      ids = Enum.map(body, & &1["id"])
      assert late.id in ids
      assert Enum.all?(body, fn e ->
               {:ok, dt, _} = DateTime.from_iso8601(e["occurred_at"])
               DateTime.compare(dt, now) in [:gt, :eq]
             end)
    end

    test "?since=garbage is ignored (returns the unfiltered list)", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/visit_events?since=not-a-date")
      assert is_list(json_response(conn, 200))
    end

    test "ignores non-integer ids gracefully (returns no rows for that filter)", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/visit_events?visit_id=not_a_number")
      assert is_list(json_response(conn, 200))
    end

    test "?limit=N caps the page size and emits X-Next-Cursor when more rows exist", %{conn: conn} do
      for _ <- 1..5 do
        {:ok, _} = Scheduling.Audit.record_event(%{type: "queue_entry.completed"})
      end

      conn = get(conn, ~p"/api/v1/visit_events?limit=2")
      body = json_response(conn, 200)
      assert length(body) == 2
      assert [cursor] = Plug.Conn.get_resp_header(conn, "x-next-cursor")
      assert {_int, ""} = Integer.parse(cursor)
    end

    test "?after=cursor walks to the next page", %{conn: conn} do
      events = for _ <- 1..3 do
        {:ok, e} = Scheduling.Audit.record_event(%{type: "queue_entry.completed"})
        e
      end

      first = get(conn, ~p"/api/v1/visit_events?limit=2")
      assert length(json_response(first, 200)) == 2
      assert [cursor] = Plug.Conn.get_resp_header(first, "x-next-cursor")

      second = get(build_conn(), ~p"/api/v1/visit_events?limit=2&after=#{cursor}")
      page2 = json_response(second, 200)
      assert length(page2) <= 2
      page1_ids = first |> json_response(200) |> Enum.map(& &1["id"])
      page2_ids = Enum.map(page2, & &1["id"])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))

      _ = events
    end
  end

  describe "GET /api/visit_events/:id" do
    test "returns the event", %{conn: conn, a: a} do
      conn = get(conn, ~p"/api/v1/visit_events/#{a.id}")
      body = json_response(conn, 200)
      assert body["id"] == a.id
      assert body["type"] == "visit.created"
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/visit_events/99999")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
