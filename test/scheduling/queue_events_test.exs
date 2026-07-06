defmodule Scheduling.QueueEventsTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Catalog.Capability
  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Event Test"}))
  end

  defp xray_capability do
    Repo.insert!(Capability.changeset(%Capability{}, %{name: "XRay"}))
  end

  defp office_fixture(caps) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Event Room",
        "intake_capacity" => 1,
        "capability_ids" => Enum.map(caps, & &1.id)
      })

    office
  end

  describe "Queue.create_entry/2" do
    test "writes a queue_entry.created event tied to the entry, visit, and patient" do
      patient = patient_fixture()

      {:ok, entry} =
        Queue.create_entry(%{patient_id: patient.id, priority: 3},
          actor_type: "service",
          actor_id: "queueing-app"
        )

      [event] = Audit.list_events(%{queue_entry_id: entry.id})
      assert event.type == "queue_entry.created"
      assert event.patient_id == patient.id
      assert event.actor_type == "service"
      assert event.actor_id == "queueing-app"
      assert event.payload["priority"] == 3
    end

    test "transaction rolls back when changeset fails" do
      pre_events = length(Audit.list_events(%{}))

      assert {:error, _changeset} = Queue.create_entry(%{patient_id: nil})

      assert length(Audit.list_events(%{})) == pre_events
    end
  end

  describe "Queue.complete/2" do
    test "writes a queue_entry.completed event with assigned_office_id in the payload" do
      patient = patient_fixture()
      cap = xray_capability()
      office = office_fixture([cap])

      {:ok, entry} =
        Queue.create_entry(%{patient_id: patient.id, required_capability_ids: [cap.id]})

      {:ok, _assigned, _} = Queue.accept(entry, accepted_by: "reception-1")

      reloaded = Queue.get_entry!(entry.id)
      {:ok, _completed} = Queue.complete(reloaded, actor_type: "user", actor_id: "nurse-7")

      [completion] =
        Audit.list_events(%{queue_entry_id: entry.id, type: "queue_entry.completed"})

      assert completion.actor_type == "user"
      assert completion.actor_id == "nurse-7"
      assert completion.payload["assigned_office_id"] == office.id
    end

    test "does not record an event on an invalid state transition" do
      patient = patient_fixture()
      {:ok, entry} = Queue.create_entry(%{patient_id: patient.id})

      pre_completions =
        Audit.list_events(%{queue_entry_id: entry.id, type: "queue_entry.completed"})
        |> length()

      # Completing a waiting (not assigned/in_service) entry must fail.
      assert {:error, _changeset} = Queue.complete(entry)

      post_completions =
        Audit.list_events(%{queue_entry_id: entry.id, type: "queue_entry.completed"})
        |> length()

      assert post_completions == pre_completions
    end
  end

  describe "Handoffs.acknowledge/2" do
    test "writes a handoff.acknowledged event with the actor" do
      patient = patient_fixture()
      cap = xray_capability()
      office = office_fixture([cap])

      {:ok, entry} =
        Queue.create_entry(%{patient_id: patient.id, required_capability_ids: [cap.id]})

      {:ok, _assigned, _} = Queue.accept(entry)

      [handoff] = Handoffs.list_pending_for_office(office.id)

      {:ok, _acked} = Handoffs.acknowledge(handoff, acknowledged_by: "nurse-7")

      [event] = Audit.list_events(%{handoff_id: handoff.id})
      assert event.type == "handoff.acknowledged"
      # Falls back to actor_type=user, actor_id=acknowledged_by when not passed explicitly
      assert event.actor_type == "user"
      assert event.actor_id == "nurse-7"
      assert event.payload["acknowledged_by"] == "nurse-7"
    end

    test "second acknowledge attempt does not write a duplicate event" do
      patient = patient_fixture()
      cap = xray_capability()
      _office = office_fixture([cap])

      {:ok, entry} =
        Queue.create_entry(%{patient_id: patient.id, required_capability_ids: [cap.id]})

      {:ok, _assigned, _} = Queue.accept(entry)
      [handoff] = Handoffs.list_pending()
      {:ok, acked} = Handoffs.acknowledge(handoff, acknowledged_by: "nurse-7")

      # Double-ack should fail on the state guard and NOT create another event.
      assert {:error, _changeset} = Handoffs.acknowledge(acked, acknowledged_by: "nurse-7")

      events = Audit.list_events(%{handoff_id: handoff.id, type: "handoff.acknowledged"})
      assert length(events) == 1
    end
  end
end
