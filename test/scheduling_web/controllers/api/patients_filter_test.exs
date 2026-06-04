defmodule SchedulingWeb.Api.PatientsFilterTest do
  @moduledoc """
  Coverage for the integration-friendly id filters on GET /api/v1/patients
  (sc-13t). Each id column has a unique index, so a filter query returns
  zero or one row. The intake-scheduling-bridge is the primary consumer —
  it uses ?intake_patient_id= to skip the O(N) list-and-filter pattern.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Patients
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo

  defp patient_fixture(attrs) do
    attrs = Map.merge(%{name: "Patient #{System.unique_integer([:positive])}"}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  describe "GET /api/v1/patients with no filter" do
    test "returns the full list sorted by name", %{conn: conn} do
      patient_fixture(%{name: "Bravo"})
      patient_fixture(%{name: "Alpha"})

      conn = get(conn, ~p"/api/v1/patients")
      body = json_response(conn, 200)
      names = Enum.map(body, & &1["name"])
      assert names == Enum.sort(names)
    end
  end

  describe "?intake_patient_id=" do
    test "returns the one matching row", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      target = patient_fixture(%{intake_patient_id: uuid})
      _other = patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})

      conn = get(conn, ~p"/api/v1/patients?intake_patient_id=#{uuid}")
      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target.id
    end

    test "returns an empty list when nothing matches", %{conn: conn} do
      patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})

      conn = get(conn, ~p"/api/v1/patients?intake_patient_id=00000000-0000-0000-0000-000000000000")
      assert [] = json_response(conn, 200)
    end
  end

  describe "?external_id=" do
    test "returns the one matching row", %{conn: conn} do
      target = patient_fixture(%{external_id: "checkin-7a3f"})
      _other = patient_fixture(%{external_id: "checkin-other"})

      conn = get(conn, ~p"/api/v1/patients?external_id=checkin-7a3f")
      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target.id
    end
  end

  describe "?client_id=" do
    test "returns the one matching row", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      target = patient_fixture(%{client_id: uuid})
      _other = patient_fixture(%{})

      conn = get(conn, ~p"/api/v1/patients?client_id=#{uuid}")
      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target.id
    end
  end

  describe "filter composition" do
    test "filters AND together", %{conn: conn} do
      # Both id columns carry a unique index, so individually each filter
      # returns 0 or 1 row. Combining them AND-style is meaningful only when
      # the two filters point at different rows: result is empty, NOT a union.
      uuid = Ecto.UUID.generate()
      target = patient_fixture(%{intake_patient_id: uuid, external_id: "match"})
      _other = patient_fixture(%{external_id: "different"})

      # Both filters point to target → one row.
      conn = get(conn, ~p"/api/v1/patients?intake_patient_id=#{uuid}&external_id=match")
      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == target.id

      # intake_patient_id matches target but external_id matches the other
      # patient → AND yields no rows. (Critical: this is not OR.)
      conn2 =
        build_conn() |> get(~p"/api/v1/patients?intake_patient_id=#{uuid}&external_id=different")

      assert [] = json_response(conn2, 200)
    end

    test "empty-string filter is treated as no filter", %{conn: conn} do
      patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})
      patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})

      conn = get(conn, ~p"/api/v1/patients?intake_patient_id=")
      assert length(json_response(conn, 200)) >= 2
    end
  end

  describe "Patients.list_patients/1 (context-level)" do
    test "ignores unknown filter keys" do
      patient_fixture(%{intake_patient_id: Ecto.UUID.generate()})

      assert is_list(Patients.list_patients(%{bogus_filter: "anything"}))
    end
  end
end
