defmodule SchedulingWeb.Api.QueueWaitEstimateTest do
  @moduledoc """
  GET /api/v1/queue_entries/:id/wait_estimate — the patient-facing position read
  (sc-ckz). Phase 1 returns position only; estimated_minutes is null.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Repo

  defp waiting(attrs \\ %{}) do
    p =
      Repo.insert!(
        Patient.changeset(%Patient{}, %{name: "P #{System.unique_integer([:positive])}"})
      )

    {:ok, entry} = Queue.create_entry(Map.merge(%{"patient_id" => p.id}, attrs))
    entry
  end

  test "returns the entry's position and a null estimate", %{conn: conn} do
    first = waiting()
    second = waiting()

    assert %{"position" => 1, "estimated_minutes" => nil} =
             conn
             |> get(~p"/api/v1/queue_entries/#{first.id}/wait_estimate")
             |> json_response(200)

    assert %{"position" => 2, "estimated_minutes" => nil} =
             conn
             |> get(~p"/api/v1/queue_entries/#{second.id}/wait_estimate")
             |> json_response(200)
  end

  test "404 for an entry that does not exist", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> get(~p"/api/v1/queue_entries/999999/wait_estimate")
             |> json_response(404)
  end
end
