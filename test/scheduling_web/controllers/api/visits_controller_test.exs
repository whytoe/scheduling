defmodule SchedulingWeb.Api.VisitControllerTest do
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Patients.Patient
  alias Scheduling.Repo

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "API Visit"}))
  end

  describe "POST /api/visits" do
    test "creates an active visit and returns 201", %{conn: conn} do
      patient = patient_fixture()

      conn = post(conn, ~p"/api/v1/visits", visit: %{patient_id: patient.id})
      body = json_response(conn, 201)

      assert body["status"] == "active"
      assert body["patient_id"] == patient.id
      assert body["ended_at"] == nil
      assert body["started_at"] != nil
    end

    test "returns 422 when patient_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/visits", visit: %{})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["patient_id"] == ["can't be blank"]
    end
  end

  describe "GET /api/visits/:id" do
    test "returns the visit", %{conn: conn} do
      patient = patient_fixture()
      create = post(conn, ~p"/api/v1/visits", visit: %{patient_id: patient.id})
      %{"id" => id} = json_response(create, 201)

      conn = build_conn() |> get(~p"/api/v1/visits/#{id}")
      assert %{"id" => ^id, "status" => "active"} = json_response(conn, 200)
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/visits/99999")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/visits/:id/end" do
    test "stamps ended status and is idempotent", %{conn: conn} do
      patient = patient_fixture()
      create = post(conn, ~p"/api/v1/visits", visit: %{patient_id: patient.id})
      %{"id" => id} = json_response(create, 201)

      first = build_conn() |> post(~p"/api/v1/visits/#{id}/end")
      assert %{"status" => "ended", "ended_at" => ended_at} = json_response(first, 200)
      refute is_nil(ended_at)

      again = build_conn() |> post(~p"/api/v1/visits/#{id}/end")
      assert %{"status" => "ended"} = json_response(again, 200)
    end
  end
end
