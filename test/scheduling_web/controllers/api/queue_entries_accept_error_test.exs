defmodule SchedulingWeb.Api.QueueEntriesAcceptErrorTest do
  @moduledoc """
  Asserts the unified error envelope (sc-2y8) on a non-validation error path:
  the 409 `no_eligible_office` conflict rendered directly by the accept action.

  Compliance is `:not_configured` in the test env (no api_key), so the accept
  flow skips the gate and reaches the matcher. A required capability that no
  office provides yields `no_eligible_office`.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  test "accept with no eligible office returns the unified error envelope", %{conn: conn} do
    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Jane Doe"}))
    mri = Repo.insert!(Capability.changeset(%Capability{}, %{name: "MRI"}))

    entry =
      %QueueEntry{}
      |> QueueEntry.changeset(%{patient_id: patient.id})
      |> Repo.insert!()
      |> Repo.preload(:required_capabilities)
      |> QueueEntry.required_capabilities_changeset([mri])
      |> Repo.update!()

    conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/accept")

    assert %{"error" => error} = json_response(conn, 409)
    assert error["code"] == "no_eligible_office"
    assert is_binary(error["message"])
    # A code-only envelope omits details entirely.
    refute Map.has_key?(error, "details")
  end
end
