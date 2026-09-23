defmodule Scheduling.QueueReplayTest do
  @moduledoc """
  Queue.replay_pending/1 retries entries stuck :waiting after a *transient*
  accept failure (no_eligible_office / compliance_unavailable), and leaves
  genuine compliance failures and never-attempted entries alone (sc-ais).
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Catalog
  alias Scheduling.Matching.Result
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp patient(name \\ "P"),
    do:
      Repo.insert!(
        Patient.changeset(%Patient{}, %{name: "#{name} #{System.unique_integer([:positive])}"})
      )

  defp capability(name) do
    {:ok, c} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    c
  end

  defp office(capability_ids, capacity \\ 2) do
    {:ok, o} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    o
  end

  defp waiting_entry(cap) do
    {:ok, e} =
      Queue.create_entry(%{"patient_id" => patient().id, "required_capability_ids" => [cap.id]})

    e
  end

  describe "no_eligible_office replay" do
    test "retries and assigns once an office can serve the entry" do
      cap = capability("CT")
      entry = waiting_entry(cap)
      # No office provides `cap` yet, so accept fails transiently.
      assert {:no_eligible_office, _} = Queue.accept(Queue.get_entry!(entry.id))
      assert Queue.get_entry!(entry.id).status == :waiting

      # An office appears that can serve it.
      office([cap.id])

      assert %{attempted: 1, assigned: 1, still_waiting: 0} = Queue.replay_pending()
      assert Queue.get_entry!(entry.id).status == :assigned
    end

    test "leaves an entry still waiting when the retry fails again" do
      cap = capability("MRI")
      entry = waiting_entry(cap)
      assert {:no_eligible_office, _} = Queue.accept(Queue.get_entry!(entry.id))

      # Still no office: the retry fails again and the entry waits for next pass.
      assert %{attempted: 1, assigned: 0, still_waiting: 1} = Queue.replay_pending()
      assert Queue.get_entry!(entry.id).status == :waiting
    end
  end

  describe "compliance_unavailable replay" do
    test "an entry whose last decision was compliance_unavailable is retried" do
      cap = capability("Consult")
      office([cap.id])
      entry = waiting_entry(cap)

      # Simulate the decision intake-down leaves behind.
      Audit.record_decision(entry, %Result{
        required: [],
        eligible: [],
        chosen: nil,
        rationale: "Compliance check unavailable: intake answered 503"
      })

      assert %{attempted: 1, assigned: 1} = Queue.replay_pending()
      assert Queue.get_entry!(entry.id).status == :assigned
    end
  end

  describe "what it leaves alone" do
    test "a genuine compliance_failed entry is not retried" do
      cap = capability("XRay")
      office([cap.id])
      entry = waiting_entry(cap)

      Audit.record_decision(entry, %Result{
        required: [],
        eligible: [],
        chosen: nil,
        rationale: "Compliance check failed for reference cref_abc"
      })

      assert %{attempted: 0} = Queue.replay_pending()
      assert Queue.get_entry!(entry.id).status == :waiting
    end

    test "a never-attempted waiting entry is not a candidate" do
      cap = capability("Dialysis")
      office([cap.id])
      _entry = waiting_entry(cap)

      assert %{attempted: 0} = Queue.replay_pending()
    end

    test "stuck_entry_ids honours :limit" do
      cap = capability("Echo")

      for _ <- 1..3 do
        e = waiting_entry(cap)

        Audit.record_decision(e, %Result{
          required: [],
          eligible: [],
          chosen: nil,
          rationale: "No eligible office: none"
        })
      end

      assert length(Audit.stuck_entry_ids(limit: 2)) == 2
      assert length(Audit.stuck_entry_ids(limit: 10)) == 3
    end
  end
end
