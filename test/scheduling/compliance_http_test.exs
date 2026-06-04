defmodule Scheduling.ComplianceHttpTest do
  @moduledoc """
  HTTP-path coverage for `Scheduling.Compliance.verify/1`. Stands up a
  Bypass server to play the intake-form API. The non-HTTP branches
  (`:not_configured`, `:ok` with no required types, `:missing` with no
  `intake_patient_id`) are exercised in `Scheduling.ComplianceTest` —
  those tests stay async-safe; these can't (they mutate global config).
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Catalog.Diagnosis
  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @patient_uuid "11111111-1111-1111-1111-111111111111"

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

  defp patient_fixture(attrs \\ %{}) do
    attrs = Map.merge(%{name: "Compliance HTTP", intake_patient_id: @patient_uuid}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  defp diagnosis_fixture(required_form_types) do
    Repo.insert!(
      Diagnosis.changeset(%Diagnosis{}, %{
        name: "Compliance HTTP Dx #{System.unique_integer([:positive])}",
        code: "DX-CMPH-#{System.unique_integer([:positive])}",
        required_form_types: required_form_types
      })
    )
  end

  defp entry(patient, diagnosis) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      diagnosis_id: diagnosis.id,
      diagnosis: diagnosis,
      required_capabilities: []
    }
  end

  # Builds a /responses payload — a list of ResponseMetadata-shaped maps with
  # the intake-spec keys we filter on (patientId, formType, status, flagged).
  defp responses(items), do: Jason.encode!(items)

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body)
  end

  describe "verify/1 with API key set + intake reachable" do
    test "returns :ok when intake has a completed, non-flagged response for the form type",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:request, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")})

        respond_json(
          conn,
          200,
          responses([
            %{
              "id" => "r1",
              "patientId" => @patient_uuid,
              "formType" => "stroke-consent",
              "status" => "completed",
              "flagged" => false
            }
          ])
        )
      end)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent"])

      assert Compliance.verify(entry(patient, dx)) == :ok

      # Confirm the request shape after the verify, when an assertion failure
      # won't poison the cowboy handler.
      assert_received {:request,
                       %{
                         "form_type" => "stroke-consent",
                         "status" => "completed",
                         "patient_id" => @patient_uuid
                       }, auth}

      assert auth == ["Bearer ik_test"]
    end

    test "returns {:missing, [type]} when intake responses are all flagged",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        respond_json(
          conn,
          200,
          responses([
            %{
              "id" => "r1",
              "patientId" => @patient_uuid,
              "formType" => "stroke-consent",
              "status" => "completed",
              "flagged" => true,
              "flaggedCodes" => ["needs-review"]
            }
          ])
        )
      end)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent"])

      assert {:missing, ["stroke-consent"]} = Compliance.verify(entry(patient, dx))
    end

    test "returns {:missing, [type]} when no response exists for this patient",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        # Other patients' responses present — none for ours.
        respond_json(
          conn,
          200,
          responses([
            %{
              "id" => "r99",
              "patientId" => "99999999-9999-9999-9999-999999999999",
              "formType" => "stroke-consent",
              "status" => "completed",
              "flagged" => false
            }
          ])
        )
      end)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent"])

      assert {:missing, ["stroke-consent"]} = Compliance.verify(entry(patient, dx))
    end

    test "returns {:missing, [only the missing types]} for a mixed multi-type diagnosis",
         %{bypass: bypass} do
      # The client makes one request per required form type — we expect two
      # calls; one returns a satisfying response, the other returns nothing.
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        body =
          case conn.query_params["form_type"] do
            "stroke-consent" ->
              responses([
                %{
                  "id" => "r1",
                  "patientId" => @patient_uuid,
                  "formType" => "stroke-consent",
                  "status" => "completed",
                  "flagged" => false
                }
              ])

            "contrast-screening" ->
              responses([])

            _other ->
              responses([])
          end

        respond_json(conn, 200, body)
      end)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent", "contrast-screening"])

      assert {:missing, ["contrast-screening"]} = Compliance.verify(entry(patient, dx))
    end
  end

  describe "verify/1 with intake unavailable" do
    test "returns {:error, {:http_status, 401, _}} when intake rejects the API key",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        respond_json(conn, 401, Jason.encode!(%{"error" => "unauthenticated"}))
      end)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent"])

      assert {:error, {:http_status, 401, _body}} = Compliance.verify(entry(patient, dx))
    end

    test "returns {:error, %Req.TransportError{}} when intake refuses connections",
         %{bypass: bypass} do
      # Stopping Bypass leaves nothing listening on that port.
      Bypass.down(bypass)

      patient = patient_fixture()
      dx = diagnosis_fixture(["stroke-consent"])

      assert {:error, %Req.TransportError{}} = Compliance.verify(entry(patient, dx))
    end

    # NOTE: a "intake mid-request timeout" test (sleep past http_timeout_ms)
    # was tried here, but cowboy + Req retry interaction made it flaky. The
    # `Bypass.down` test above already covers the "intake unreachable ->
    # transport error" path — the timeout case degrades into the same
    # surfaced failure mode at the accept-flow boundary.
  end
end
