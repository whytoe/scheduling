defmodule SchedulingWeb.Api.QueueEntriesFilterTest do
  @moduledoc """
  Coverage for the integration-friendly id filters on GET /api/v1/queue_entries
  (sc-phj). Mirrors the patient list endpoint filters: each id column on
  `patients` is uniquely indexed, so a server-side join + where returns the
  exact set of queue entries for that patient. Used by the
  intake-scheduling-bridge to dedupe waiting entries without a list-and-walk.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Repo

  defp patient_fixture(attrs) do
    attrs = Map.merge(%{name: "P #{System.unique_integer([:positive])}"}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  defp waiting_entry(patient, attrs \\ %{}) do
    attrs = Map.merge(%{patient_id: patient.id}, Map.new(attrs))
    {:ok, entry} = Queue.create_entry(attrs)
    entry
  end

  describe "?intake_patient_id= (primary bridge use case)" do
    test "returns only entries for that patient", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      target_patient = patient_fixture(%{intake_patient_id: uuid})
      other_patient = patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})

      target_entry = waiting_entry(target_patient)
      _other_entry = waiting_entry(other_patient)

      conn =
        get(conn, ~p"/api/v1/queue_entries?intake_patient_id=#{uuid}&status=waiting")

      body = json_response(conn, 200)
      assert [%{"id" => id, "patient_id" => pid}] = body
      assert id == target_entry.id
      assert pid == target_patient.id
    end

    test "returns empty list when patient has no waiting entries", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      _patient_no_entries = patient_fixture(%{intake_patient_id: uuid})

      conn = get(conn, ~p"/api/v1/queue_entries?intake_patient_id=#{uuid}&status=waiting")
      assert [] = json_response(conn, 200)
    end

    test "returns empty list when uuid doesn't match any patient", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/api/v1/queue_entries?intake_patient_id=00000000-0000-0000-0000-000000000000"
        )

      assert [] = json_response(conn, 200)
    end
  end

  describe "?patient_id= (scheduling-side int)" do
    test "returns entries for that patient id", %{conn: conn} do
      target = patient_fixture(%{})
      other = patient_fixture(%{})

      target_entry = waiting_entry(target)
      _other_entry = waiting_entry(other)

      conn = get(conn, ~p"/api/v1/queue_entries?patient_id=#{target.id}")

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target_entry.id
    end

    test "non-integer patient_id is silently dropped (no filter)", %{conn: conn} do
      target = patient_fixture(%{})
      _entry = waiting_entry(target)

      conn = get(conn, ~p"/api/v1/queue_entries?patient_id=not_a_number")
      body = json_response(conn, 200)
      assert is_list(body)
      assert length(body) >= 1
    end
  end

  describe "?external_id= and ?client_id=" do
    test "external_id matches", %{conn: conn} do
      target = patient_fixture(%{external_id: "checkin-7a3f"})
      other = patient_fixture(%{external_id: "checkin-other"})

      target_entry = waiting_entry(target)
      _other_entry = waiting_entry(other)

      conn = get(conn, ~p"/api/v1/queue_entries?external_id=checkin-7a3f")
      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target_entry.id
    end

    test "client_id matches", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      target = patient_fixture(%{client_id: uuid})
      _other = patient_fixture(%{})

      _target_entry = waiting_entry(target)
      conn = get(conn, ~p"/api/v1/queue_entries?client_id=#{uuid}")

      assert [%{"patient_id" => pid}] = json_response(conn, 200)
      assert pid == target.id
    end
  end

  describe "composition with ?status=" do
    test "?intake_patient_id= + ?status=waiting returns only that patient's waiting entries",
         %{conn: conn} do
      uuid = Ecto.UUID.generate()
      patient = patient_fixture(%{intake_patient_id: uuid})
      waiting = waiting_entry(patient)

      # Force a second entry then mark it completed via the lifecycle path.
      # The "completed" entry should be excluded by ?status=waiting.
      completed = waiting_entry(patient)

      {:ok, _} =
        completed
        |> Scheduling.Queue.QueueEntry.changeset(%{
          status: :assigned,
          assigned_office_id: nil
        })
        |> then(fn cs -> Scheduling.Repo.update(cs) end)

      conn = get(conn, ~p"/api/v1/queue_entries?intake_patient_id=#{uuid}&status=waiting")
      body = json_response(conn, 200)
      ids = Enum.map(body, & &1["id"])
      assert waiting.id in ids
      refute completed.id in ids
    end
  end
end
