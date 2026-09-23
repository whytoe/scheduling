defmodule Scheduling.QueueDispositionTest do
  @moduledoc """
  Queue.discharge_with_followup/3 — the disposition half of sc-7hu: complete an
  entry AND spin up a follow-up in the same visit, emitting followup.scheduled
  (the sc-nm5 signal).
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Visits

  defp capability(name) do
    {:ok, c} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    c
  end

  defp office(capability_ids),
    do:
      (fn ->
         {:ok, o} =
           Offices.create_office(%{
             "name" => "Room #{System.unique_integer([:positive])}",
             "intake_capacity" => 3,
             "capability_ids" => capability_ids
           })

         o
       end).()

  # An assigned entry, on a real visit, ready to discharge.
  defp assigned_entry(cap) do
    patient =
      Repo.insert!(
        Patient.changeset(%Patient{}, %{name: "P #{System.unique_integer([:positive])}"})
      )

    {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})

    {:ok, entry} =
      Queue.create_entry(%{
        "patient_id" => patient.id,
        "visit_id" => visit.id,
        "required_capability_ids" => [cap.id]
      })

    {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))
    {assigned, visit, patient}
  end

  describe "discharge_with_followup/3" do
    test "discharges the entry and creates a follow-up in the same visit" do
      cap = capability("Consult")
      office([cap.id])
      followup_cap = capability("Imaging")
      office([followup_cap.id])
      {entry, visit, patient} = assigned_entry(cap)

      assert {:ok, discharged, followup} =
               Queue.discharge_with_followup(entry, %{
                 "required_capability_ids" => [followup_cap.id]
               })

      assert discharged.status == :discharged_with_followup
      assert followup.status == :waiting
      assert followup.visit_id == visit.id
      assert followup.patient_id == patient.id
      assert Enum.map(followup.required_capabilities, & &1.id) == [followup_cap.id]
    end

    test "a future scheduled_for makes the follow-up :scheduled" do
      cap = capability("Consult")
      office([cap.id])
      {entry, _visit, _patient} = assigned_entry(cap)
      later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      assert {:ok, _discharged, followup} =
               Queue.discharge_with_followup(entry, %{"scheduled_for" => later})

      assert followup.status == :scheduled
    end

    test "patient and visit cannot be redirected by next_entry" do
      cap = capability("Consult")
      office([cap.id])
      {entry, visit, patient} = assigned_entry(cap)

      {:ok, _discharged, followup} =
        Queue.discharge_with_followup(entry, %{"patient_id" => 999_999, "visit_id" => 888_888})

      assert followup.patient_id == patient.id
      assert followup.visit_id == visit.id
    end

    test "carries required_compliance_refs onto the follow-up" do
      cap = capability("Consult")
      office([cap.id])
      {entry, _visit, _patient} = assigned_entry(cap)

      {:ok, _discharged, followup} =
        Queue.discharge_with_followup(entry, %{"required_compliance_refs" => ["cref_x"]})

      assert followup.required_compliance_refs == ["cref_x"]
    end

    test "emits followup.scheduled and the discharge event; nothing clinical in payloads" do
      cap = capability("Consult")
      office([cap.id])
      {entry, visit, _patient} = assigned_entry(cap)

      {:ok, _discharged, _followup} =
        Queue.discharge_with_followup(entry, %{"required_capability_ids" => [cap.id]})

      types =
        Audit.list_events(%{}) |> Enum.filter(&(&1.visit_id == visit.id)) |> Enum.map(& &1.type)

      assert "queue_entry.discharged_with_followup" in types
      assert "followup.scheduled" in types

      [event] =
        Audit.list_events(type: "followup.scheduled") |> Enum.filter(&(&1.visit_id == visit.id))

      assert Map.keys(event.payload) |> Enum.sort() == ["scheduled_for", "status"]
    end

    test "refuses to discharge an entry that is not in service, changing nothing" do
      cap = capability("Consult")
      office([cap.id])
      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Waiter"}))
      {:ok, visit} = Visits.create_visit(%{patient_id: patient.id})
      {:ok, waiting} = Queue.create_entry(%{"patient_id" => patient.id, "visit_id" => visit.id})

      assert {:error, _changeset} =
               Queue.discharge_with_followup(waiting, %{"required_capability_ids" => []})

      assert Queue.get_entry!(waiting.id).status == :waiting
      # No follow-up leaked in.
      assert Queue.list_waiting_entries() |> Enum.map(& &1.id) == [waiting.id]
    end
  end
end
