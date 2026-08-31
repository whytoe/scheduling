defmodule Scheduling.ComplianceHttpTest do
  @moduledoc """
  HTTP-path coverage for `Scheduling.Compliance.verify/1`, with a Bypass server
  playing the intake-form API. The branches that never reach HTTP are covered
  in `Scheduling.ComplianceTest`.

  The gate sends **opaque references**, never form-type names — that is the
  whole point of the design (`docs/data-boundary.md`), so there is a test below
  asserting it directly rather than trusting it by inspection.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @patient_uuid "11111111-1111-1111-1111-111111111111"
  @ref_a "cref_7f3a91c4e2b8"
  @ref_b "cref_0b2e5d9a1c74"

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

  defp entry(patient, refs \\ [@ref_a]) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      required_compliance_refs: refs,
      required_capabilities: []
    }
  end

  defp stub_responses(bypass, fun) do
    Bypass.expect(bypass, "GET", "/api/v1/responses", fun)
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # One completed response means the requirement is satisfied. The row shape is
  # intake's; only its presence matters here.
  defp a_completed_response, do: [%{"id" => "resp_1", "status" => "completed"}]

  describe "verify/1 verdicts" do
    test "a satisfied reference returns :ok", %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 200, a_completed_response()))

      assert Compliance.verify(entry(patient_fixture())) == :ok
    end

    test "no completed response blocks, naming the reference", %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 200, []))

      assert Compliance.verify(entry(patient_fixture())) == {:blocked, [@ref_a]}
    end

    test "blocks on every unmet reference, not just the first", %{bypass: bypass} do
      # Both outstanding: the front desk should be able to list both rather
      # than sending the patient away twice.
      stub_responses(bypass, &respond(&1, 200, []))

      assert Compliance.verify(entry(patient_fixture(), [@ref_a, @ref_b])) ==
               {:blocked, [@ref_a, @ref_b]}
    end

    test "blocks only on the unmet one when the other is satisfied", %{bypass: bypass} do
      stub_responses(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["compliance_ref"] do
          @ref_a -> respond(conn, 200, a_completed_response())
          _ -> respond(conn, 200, [])
        end
      end)

      assert Compliance.verify(entry(patient_fixture(), [@ref_a, @ref_b])) ==
               {:blocked, [@ref_b]}
    end

    test "tolerates a wrapped list, since the envelope isn't fixed yet",
         %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 200, %{"data" => a_completed_response()}))

      assert Compliance.verify(entry(patient_fixture())) == :ok
    end
  end

  describe "verify/1 failures are fail-closed" do
    test "an unrecognised reference is an error, not a block", %{bypass: bypass} do
      # 400 means intake cannot resolve the reference — a stale cref_ left
      # behind after a form type was retired. That is our configuration being
      # wrong, not the patient being non-compliant, and the accept flow renders
      # the two differently. Treating it as a block would tell someone at the
      # desk that a patient owes paperwork they do not owe.
      stub_responses(bypass, &respond(&1, 400, %{"error" => "unknown_reference"}))

      assert {:error, {:unknown_reference, @ref_a}} =
               Compliance.verify(entry(patient_fixture()))
    end

    test "one unknown reference fails the whole check", %{bypass: bypass} do
      # Not "check the others and hope" — a reference we cannot resolve means
      # the requirement set is not fully known, so no verdict is safe.
      stub_responses(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["compliance_ref"] do
          @ref_a -> respond(conn, 200, a_completed_response())
          _ -> respond(conn, 400, %{"error" => "unknown_reference"})
        end
      end)

      assert {:error, {:unknown_reference, @ref_b}} =
               Compliance.verify(entry(patient_fixture(), [@ref_a, @ref_b]))
    end

    test "a server error is an error", %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 500, %{"error" => "boom"}))

      assert {:error, {:http_status, 500, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "a body that is not a list of responses is an error", %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 200, %{"status" => "maybe"}))

      assert {:error, {:unexpected_body, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "an unreachable intake is an error", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, _reason} = Compliance.verify(entry(patient_fixture()))
    end
  end

  describe "the request itself" do
    test "carries the reference, the patient id, completed status and the token",
         %{bypass: bypass} do
      test_pid = self()

      stub_responses(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:req, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")})
        respond(conn, 200, a_completed_response())
      end)

      assert Compliance.verify(entry(patient_fixture())) == :ok

      assert_receive {:req, params, ["Bearer ik_test"]}
      assert params["compliance_ref"] == @ref_a
      assert params["patient_id"] == @patient_uuid
      assert params["status"] == "completed"
    end

    test "sends no clinical detail — only opaque references", %{bypass: bypass} do
      # The guarantee this whole design exists for. If a future change starts
      # sending form types again, this fails.
      test_pid = self()

      stub_responses(bypass, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        respond(conn, 200, a_completed_response())
      end)

      Compliance.verify(entry(patient_fixture()))

      assert_receive {:params, params}

      assert params |> Map.keys() |> Enum.sort() ==
               ["compliance_ref", "limit", "patient_id", "status"]

      refute Enum.any?(Map.values(params), &String.contains?(&1, "consent"))
    end

    test "asks about a reference only once, even if it is listed twice",
         %{bypass: bypass} do
      test_pid = self()

      stub_responses(bypass, fn conn ->
        send(test_pid, :asked)
        respond(conn, 200, a_completed_response())
      end)

      assert Compliance.verify(entry(patient_fixture(), [@ref_a, @ref_a])) == :ok

      assert_receive :asked
      refute_receive :asked, 200
    end
  end
end
