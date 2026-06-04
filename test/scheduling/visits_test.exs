defmodule Scheduling.VisitsTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Patients.Patient
  alias Scheduling.Visits
  alias Scheduling.Visits.Visit

  defp patient_fixture(attrs \\ %{}) do
    attrs = Map.merge(%{name: "Visit Test"}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  describe "create_visit/2" do
    test "creates an active visit with started_at defaulted to now" do
      patient = patient_fixture()

      before = DateTime.utc_now() |> DateTime.add(-1, :second)
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})

      assert visit.status == :active
      assert visit.ended_at == nil
      assert DateTime.compare(visit.started_at, before) in [:gt, :eq]
    end

    test "accepts an explicit started_at" do
      patient = patient_fixture()
      ts = ~U[2026-06-01 12:00:00Z]

      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id, started_at: ts})
      assert DateTime.compare(visit.started_at, ts) == :eq
    end

    test "requires a patient_id" do
      assert {:error, changeset} = Visits.create_visit(%{})
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "records a visit.created event tied to the visit" do
      patient = patient_fixture()

      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})

      [event] = Audit.list_events(%{visit_id: visit.id})
      assert event.type == "visit.created"
      assert event.patient_id == patient.id
      assert event.actor_type == nil
      assert DateTime.compare(event.occurred_at, visit.started_at) == :eq
    end

    test "carries actor through to the event" do
      patient = patient_fixture()

      {:ok, visit} =
        Visits.create_visit(
          %{patient_id: patient.id},
          actor_type: "service",
          actor_id: "queueing-app"
        )

      [event] = Audit.list_events(%{visit_id: visit.id})
      assert event.actor_type == "service"
      assert event.actor_id == "queueing-app"
    end

    test "transactional: invalid attrs leave no rows behind" do
      pre_events = length(Audit.list_events(%{}))
      pre_visits = Repo.aggregate(Visit, :count)

      assert {:error, _changeset} = Visits.create_visit(%{})

      assert Repo.aggregate(Visit, :count) == pre_visits
      assert length(Audit.list_events(%{})) == pre_events
    end
  end

  describe "end_visit/2" do
    test "marks the visit ended and records a visit.ended event" do
      patient = patient_fixture()
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})

      {:ok, ended} = Visits.end_visit(visit, actor_type: "user", actor_id: "nurse-7")

      assert ended.status == :ended
      assert ended.ended_at != nil

      types = Audit.list_events(%{visit_id: visit.id}) |> Enum.map(& &1.type)
      assert "visit.ended" in types
    end

    test "is idempotent: ending an already-ended visit doesn't re-event" do
      patient = patient_fixture()
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})
      {:ok, ended} = Visits.end_visit(visit)

      assert {:ok, ^ended} = Visits.end_visit(ended)

      event_count =
        Audit.list_events(%{visit_id: visit.id})
        |> Enum.count(&(&1.type == "visit.ended"))

      assert event_count == 1
    end

    test "rejects ended_at before started_at" do
      patient = patient_fixture()
      started = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id, started_at: started})
      earlier = DateTime.add(started, -60, :second)

      assert {:error, changeset} = Visits.end_visit(visit, ended_at: earlier)
      assert "must be at or after started_at" in errors_on(changeset).ended_at
    end
  end

  describe "list_visits/0 and get_visit!/1" do
    test "list returns most-recent first" do
      a = patient_fixture(%{name: "A"})
      b = patient_fixture(%{name: "B"})

      {:ok, _earlier} =
        Visits.create_visit(%{patient_id: a.id, started_at: ~U[2026-05-01 12:00:00Z]})

      {:ok, later} =
        Visits.create_visit(%{patient_id: b.id, started_at: ~U[2026-06-01 12:00:00Z]})

      [first | _] = Visits.list_visits()
      assert first.id == later.id
    end

    test "get_visit! preloads patient and queue_entries" do
      patient = patient_fixture()
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})

      reloaded = Visits.get_visit!(visit.id)
      assert reloaded.patient.id == patient.id
      assert reloaded.queue_entries == []
    end
  end
end
