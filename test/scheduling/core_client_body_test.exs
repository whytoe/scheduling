defmodule Scheduling.CoreClientBodyTest do
  @moduledoc """
  Nothing ac-core sends may travel out of `Scheduling.Core.Client` inside an
  error reason.

  `Scheduling.Core.Client` projects every *successful* response field by field
  and discards the original. A failure used to skip that entirely and hand the
  raw body onwards, so `{:error, {:http_status, 500, body}}` from
  `/v1/patients` carried a patient record — the exact content the projection
  exists to drop, on the path nobody was looking at.

  Today every sink for these reasons is a log or an operator's terminal, and
  `docs/data-boundary.md` allows patient names there, so this is hygiene rather
  than a breach: the hazard is the caller that has not been written yet.
  `sc-87w` is the same omission with a durable sink on the end of it.

  The tests below use a marker string that could only have come from the
  response body, so a leak cannot be mistaken for coincidence.

  `async: false` — points `Scheduling.Core` at a Bypass server, which is
  application env.
  """
  use Scheduling.DataCase, async: false

  import ExUnit.CaptureLog

  alias Scheduling.Core.Client
  alias Scheduling.Locations
  alias Scheduling.Patients
  alias Scheduling.Practices

  # A surname nothing else in the suite produces.
  @patient_content "Featherstonehaugh"

  # `patients.core_patient_id` is a uuid column, so the id has to be one.
  @core_id "3f2b8c1d-7a45-4e29-b0c6-4d8e1f9a2b73"

  setup do
    bypass = Bypass.open()
    original_core = Application.get_env(:scheduling, Scheduling.Core)
    original_auth = Application.get_env(:scheduling, Scheduling.Auth)

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "scheduling-svc",
      client_secret: "shh",
      http_timeout_ms: 500
    )

    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "shh"
    )

    start_supervised!({Scheduling.ServiceTokenStub, {:ok, "svc_access_token"}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # What a failing /v1/patients call can actually answer with: ac-core declares
  # every object `additionalProperties: true`, so an error envelope may repeat
  # the record it was asked about.
  defp patient_error_body do
    %{
      "error" => "boom",
      "patient" => %{
        "id" => @core_id,
        "firstName" => "Ada",
        "lastName" => @patient_content
      }
    }
  end

  describe "the client" do
    test "does not carry a non-2xx body", %{bypass: bypass} do
      Bypass.expect(
        bypass,
        "GET",
        "/v1/patients/#{@core_id}",
        &json(&1, 403, patient_error_body())
      )

      assert {:error, reason} = Client.get_patient(@core_id)
      refute inspect(reason) =~ @patient_content
      assert reason == {:http_status, 403, {:map, 2}}
    end

    test "does not carry a 401 body", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/patients", &json(&1, 401, patient_error_body()))

      assert {:error, reason} = Client.search_patients("ada")
      refute inspect(reason) =~ @patient_content
      assert reason == {:http_status, 401, {:map, 2}}
    end

    test "does not carry a 404 body, and still classifies as :not_found", %{bypass: bypass} do
      Bypass.expect(
        bypass,
        "GET",
        "/v1/patients/#{@core_id}",
        &json(&1, 404, patient_error_body())
      )

      assert {:error, reason} = Client.get_patient(@core_id)
      refute inspect(reason) =~ @patient_content
      assert reason == {:http_status, 404, {:map, 2}}

      # The three-element form is matched on. Shortening the arity here would
      # turn every missing patient into {:core_unavailable, _} and make the
      # registry look broken instead of empty.
      assert {:error, :not_found} = Patients.resolve_from_core(@core_id)
    end

    test "does not carry a 200 body it cannot project", %{bypass: bypass} do
      # A top-level array where the client expects an envelope. Unlike the
      # compliance client, a list can reach shape/1 here.
      Bypass.expect(bypass, "GET", "/v1/patients/#{@core_id}", fn conn ->
        json(conn, 200, [patient_error_body(), patient_error_body()])
      end)

      assert {:error, reason} = Client.get_patient(@core_id)
      refute inspect(reason) =~ @patient_content
      assert reason == {:unexpected_body, {:list, 2}}
    end

    test "does not carry a non-JSON 200 body", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/patients/#{@core_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, @patient_content)
      end)

      assert {:error, reason} = Client.get_patient(@core_id)
      refute inspect(reason) =~ @patient_content
      assert reason == {:unexpected_body, {:string, byte_size(@patient_content)}}
    end
  end

  describe "the sync logs" do
    setup %{bypass: bypass} do
      # /v1/practices and /v1/locations answer with sites rather than patients,
      # but an ac-core error envelope is an ac-core error envelope — and these
      # are the only two callers that put a reason anywhere today.
      Bypass.stub(bypass, "GET", "/v1/locations", &json(&1, 403, patient_error_body()))
      Bypass.stub(bypass, "GET", "/v1/practices", &json(&1, 403, patient_error_body()))
      :ok
    end

    test "a failed location sync logs no response content" do
      log = capture_log(fn -> assert {:error, _} = Locations.sync_from_core() end)

      refute log =~ @patient_content
      assert log =~ "Location sync failed"
    end

    test "a failed practice sync logs no response content" do
      log = capture_log(fn -> assert {:error, _} = Practices.sync_from_core() end)

      refute log =~ @patient_content
      assert log =~ "Practice sync failed"
    end

    test "the log still says enough to diagnose" do
      # Stripping content must not strip meaning. An operator needs to know
      # ac-core was reachable and unhappy, and with what, not merely that
      # something failed.
      log = capture_log(fn -> Locations.sync_from_core() end)

      assert log =~ "403"
      assert log =~ "map"
    end
  end
end
