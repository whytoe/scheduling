defmodule SchedulingWeb.Api.QueueCompleteDispositionTest do
  @moduledoc "POST /queue_entries/:id/complete with a next_entry disposition (sc-7hu)."
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Repo
  alias Scheduling.Visits

  defp assigned_entry do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "Cap-#{System.unique_integer([:positive])}"})

    {:ok, _office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 3,
        "capability_ids" => [cap.id]
      })

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
    {assigned, visit, cap}
  end

  test "with next_entry: discharges and returns the follow-up", %{conn: conn} do
    {entry, visit, cap} = assigned_entry()

    body =
      conn
      |> post(~p"/api/v1/queue_entries/#{entry.id}/complete", %{
        next_entry: %{required_capability_ids: [cap.id]}
      })
      |> json_response(200)

    assert body["status"] == "discharged_with_followup"
    assert body["followup"]["status"] == "waiting"
    assert body["followup"]["visit_id"] == visit.id
    refute body["followup"]["id"] == entry.id
  end

  test "without next_entry: plain completion, unchanged shape (no followup key)", %{conn: conn} do
    {entry, _visit, _cap} = assigned_entry()

    body =
      conn
      |> post(~p"/api/v1/queue_entries/#{entry.id}/complete", %{})
      |> json_response(200)

    assert body["status"] == "completed"
    refute Map.has_key?(body, "followup")
  end
end
