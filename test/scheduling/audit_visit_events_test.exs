defmodule Scheduling.AuditVisitEventsTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Audit.VisitEvent
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Visits.Visit

  defp event!(attrs) do
    {:ok, e} = Audit.record_event(attrs)
    e
  end

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Event Test"}))
  end

  defp visit_fixture(patient) do
    Repo.insert!(
      Visit.changeset(%Visit{}, %{
        patient_id: patient.id,
        status: :active,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    )
  end

  defp entry_fixture(patient) do
    Repo.insert!(
      QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id, status: :waiting, priority: 0})
    )
  end

  describe "record_event/1" do
    test "requires a type" do
      assert {:error, changeset} = Audit.record_event(%{})
      assert "can't be blank" in errors_on(changeset).type
    end

    test "defaults occurred_at to now when omitted" do
      before = DateTime.utc_now() |> DateTime.add(-1, :second)
      e = event!(%{type: "queue_entry.created"})
      assert DateTime.compare(e.occurred_at, before) in [:gt, :eq]
    end

    test "stores payload as jsonb (string keys after reload)" do
      e = event!(%{type: "queue_entry.created", payload: %{priority: 5, diagnosis_id: 1}})
      reloaded = Audit.get_event!(e.id)
      assert reloaded.payload["priority"] == 5
      assert reloaded.payload["diagnosis_id"] == 1
    end
  end

  describe "list_events/1 filters" do
    setup do
      p1 = patient_fixture()
      p2 = patient_fixture()
      v1 = visit_fixture(p1)
      v2 = visit_fixture(p2)
      e1 = entry_fixture(p1)

      a =
        event!(%{
          type: "visit.created",
          visit_id: v1.id,
          patient_id: p1.id,
          actor_type: "service"
        })

      b =
        event!(%{
          type: "queue_entry.created",
          visit_id: v1.id,
          queue_entry_id: e1.id,
          patient_id: p1.id
        })

      c =
        event!(%{
          type: "visit.ended",
          visit_id: v2.id,
          patient_id: p2.id,
          actor_type: "user",
          actor_id: "nurse-7"
        })

      %{a: a, b: b, c: c, v1: v1, v2: v2, e1: e1, p1: p1, p2: p2}
    end

    test "by visit_id", %{a: a, b: b, v1: v1} do
      ids = Audit.list_events(%{visit_id: v1.id}) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.id, b.id])
    end

    test "by queue_entry_id", %{b: b, e1: e1} do
      assert [event] = Audit.list_events(%{queue_entry_id: e1.id})
      assert event.id == b.id
    end

    test "by type", %{c: c} do
      assert [event] = Audit.list_events(%{type: "visit.ended"})
      assert event.id == c.id
    end

    test "by actor_type and actor_id", %{c: c} do
      assert [event] = Audit.list_events(%{actor_type: "user", actor_id: "nurse-7"})
      assert event.id == c.id
    end

    test "no filters returns all events" do
      assert length(Audit.list_events(%{})) == 3
    end

    test "ignores nil-valued filters" do
      assert length(Audit.list_events(%{visit_id: nil, patient_id: nil})) == 3
    end
  end

  describe "list_events/1 ordering" do
    test "most-recent first by occurred_at then id" do
      early = event!(%{type: "x.early", occurred_at: ~U[2026-01-01 00:00:00Z]})
      late = event!(%{type: "x.late", occurred_at: ~U[2026-06-01 00:00:00Z]})

      assert [first, last] = Audit.list_events(%{})
      assert first.id == late.id
      assert last.id == early.id
    end
  end

  describe "get_event!/1" do
    test "raises when missing" do
      assert_raise Ecto.NoResultsError, fn -> Audit.get_event!(-1) end
    end

    test "fetches by id" do
      e = event!(%{type: "queue_entry.completed"})
      assert %VisitEvent{id: id} = Audit.get_event!(e.id)
      assert id == e.id
    end
  end
end
