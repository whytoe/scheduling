defmodule Scheduling.ComplianceHttpTest do
  @moduledoc """
  HTTP-path coverage for `Scheduling.Compliance.verify/1`, with a Bypass server
  playing the intake-form API. The branches that never reach HTTP are covered
  in `Scheduling.ComplianceTest`.

  The gate sends an **opaque reference**, never form-type names — that is the
  whole point of the design (`docs/data-boundary.md`), so there is a test below
  asserting it directly rather than trusting it by inspection.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @patient_uuid "11111111-1111-1111-1111-111111111111"
  @reference "enc_01HV3K7Q"

  setup do
    bypass = Bypass.open()

    original = Application.get_env(:scheduling, Compliance)

    Application.put_env(:scheduling, Compliance,
      base_url: "http://localhost:#{bypass.port}/api/v1",
      api_key: "ik_test",
      http_timeout_ms: 500
    )

    on_exit(fn -> Application.put_env(:scheduling, Compliance, original) end)

    %{bypass: bypass}
  end

  defp patient_fixture do
    Repo.insert!(
      Patient.changeset(%Patient{}, %{
        name: "Compliance HTTP",
        intake_patient_id: @patient_uuid
      })
    )
  end

  defp entry(patient, ref \\ @reference) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      compliance_ref: ref,
      required_capabilities: []
    }
  end

  defp stub_status(bypass, fun) do
    Bypass.expect(bypass, "GET", "/api/v1/compliance/status", fun)
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "verify/1 verdicts" do
    test "compliant returns :ok", %{bypass: bypass} do
      stub_status(bypass, &respond(&1, 200, %{"compliant" => true}))

      assert Compliance.verify(entry(patient_fixture())) == :ok
    end

    test "not compliant returns :blocked", %{bypass: bypass} do
      stub_status(bypass, &respond(&1, 200, %{"compliant" => false}))

      assert Compliance.verify(entry(patient_fixture())) == :blocked
    end

    test "tolerates camelCase, since the field name isn't fixed yet",
         %{bypass: bypass} do
      stub_status(bypass, &respond(&1, 200, %{"isCompliant" => false}))

      assert Compliance.verify(entry(patient_fixture())) == :blocked
    end
  end

  describe "verify/1 failures are fail-closed" do
    test "an unrecognised reference is an error, not a pass", %{bypass: bypass} do
      # A 404 means intake cannot resolve the reference. Treating that as
      # "compliant" would let an unknown encounter through the gate.
      stub_status(bypass, &respond(&1, 404, %{"error" => "not_found"}))

      assert {:error, {:http_status, 404, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "a server error is an error", %{bypass: bypass} do
      stub_status(bypass, &respond(&1, 500, %{"error" => "boom"}))

      assert {:error, {:http_status, 500, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "a body without a recognisable verdict is an error", %{bypass: bypass} do
      stub_status(bypass, &respond(&1, 200, %{"status" => "maybe"}))

      assert {:error, {:unexpected_body, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "an unreachable intake is an error", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, _reason} = Compliance.verify(entry(patient_fixture()))
    end
  end

  describe "the request itself" do
    test "carries the reference, the patient id and the bearer token",
         %{bypass: bypass} do
      test_pid = self()

      stub_status(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:req, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")})
        respond(conn, 200, %{"compliant" => true})
      end)

      assert Compliance.verify(entry(patient_fixture())) == :ok

      assert_receive {:req, params, ["Bearer ik_test"]}
      assert params["reference"] == @reference
      assert params["patient_id"] == @patient_uuid
    end

    test "sends no clinical detail — only the opaque reference", %{bypass: bypass} do
      # The guarantee this whole design exists for. If a future change starts
      # sending form types again, this fails.
      test_pid = self()

      stub_status(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        respond(conn, 200, %{"compliant" => true})
      end)

      Compliance.verify(entry(patient_fixture()))

      assert_receive {:params, params}
      assert Map.keys(params) |> Enum.sort() == ["patient_id", "reference"]
      refute Enum.any?(Map.values(params), &String.contains?(&1, "consent"))
    end
  end
end
