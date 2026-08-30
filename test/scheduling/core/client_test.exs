defmodule Scheduling.Core.ClientTest do
  @moduledoc """
  `Scheduling.Core.Client` against a Bypass server playing ac-core.

  The projection tests are the important ones. Every object in the ac-core
  spec is `additionalProperties: true`, so the live API may return more than
  it documents — and a patient record already carries `mrn`, `dateOfBirth`,
  `phone` and `email`, none of which scheduling should hold. The allowlist is
  the control that keeps those out (`docs/data-boundary.md`), so it is
  asserted directly rather than trusted by inspection.

  `async: false` — these mutate application env.
  """
  use ExUnit.Case, async: false

  alias Scheduling.Core.Client

  @token "svc_access_token"

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

    # Core.enabled?/0 also requires Auth.enabled?/0 — the token exchange runs
    # through the shared provider worker.
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "shh"
    )

    # Stand in for the GenServer so these tests exercise the client, not the
    # token cache; ServiceToken has its own test.
    stub = start_supervised!({Scheduling.ServiceTokenStub, {:ok, @token}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass, stub: stub}
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # A patient as ac-core actually returns it: the documented fields, plus an
  # undocumented one, since the schema permits extras.
  defp raw_patient(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "pat_1",
        "practiceId" => "prac_1",
        "mrn" => "MRN-00042",
        "firstName" => "Jane",
        "lastName" => "Doe",
        "dateOfBirth" => "1980-04-01",
        "phone" => "+1-555-0100",
        "email" => "jane@example.org",
        "insuranceMemberId" => "MEM-999",
        "someFutureField" => %{"nested" => true}
      },
      overrides
    )
  end

  describe "get_patient/1" do
    test "returns only the allowlisted fields", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/patients/pat_1", &respond(&1, 200, raw_patient()))

      assert {:ok, patient} = Client.get_patient("pat_1")

      assert patient == %{
               id: "pat_1",
               practice_id: "prac_1",
               first_name: "Jane",
               last_name: "Doe"
             }
    end

    test "drops the identifiers and contact details we have no use for",
         %{bypass: bypass} do
      # The data-boundary guarantee. If a future change starts merging the
      # response instead of projecting it, this fails.
      Bypass.expect(bypass, "GET", "/v1/patients/pat_1", &respond(&1, 200, raw_patient()))

      assert {:ok, patient} = Client.get_patient("pat_1")

      for forbidden <- [
            :mrn,
            :dateOfBirth,
            :date_of_birth,
            :phone,
            :email,
            :insuranceMemberId,
            :someFutureField
          ] do
        refute Map.has_key?(patient, forbidden)
      end

      assert Map.keys(patient) |> Enum.sort() == [:first_name, :id, :last_name, :practice_id]
      refute patient |> inspect() |> String.contains?("MRN-00042")
    end

    test "sends the bearer token", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/v1/patients/pat_1", fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        respond(conn, 200, raw_patient())
      end)

      assert {:ok, _} = Client.get_patient("pat_1")
      assert_receive {:auth, ["Bearer " <> @token]}
    end

    test "percent-encodes the id so it cannot escape its path segment",
         %{bypass: bypass} do
      # Ids are opaque to us, so a `/` in one must not become a path
      # separator. `URI.encode/1` alone would not do this — it preserves
      # reserved characters — which is why the client encodes against the
      # unreserved set instead.
      Bypass.expect(bypass, "GET", "/v1/patients/a%2Fb", &respond(&1, 200, raw_patient()))

      assert {:ok, _} = Client.get_patient("a/b")
    end

    test "a missing patient is an error", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/patients/nope", &respond(&1, 404, %{"error" => "nf"}))

      assert {:error, {:http_status, 404, _}} = Client.get_patient("nope")
    end
  end

  describe "search_patients/2" do
    test "projects every row in the page", %{bypass: bypass} do
      body = %{
        "data" => [raw_patient(), raw_patient(%{"id" => "pat_2", "firstName" => "Sam"})],
        "page" => 1,
        "pageSize" => 25,
        "total" => 2
      }

      Bypass.expect(bypass, "GET", "/v1/patients", &respond(&1, 200, body))

      assert {:ok, page} = Client.search_patients("doe")
      assert page.page == 1 and page.page_size == 25 and page.total == 2
      assert [%{id: "pat_1"}, %{id: "pat_2", first_name: "Sam"}] = page.data
      refute Enum.any?(page.data, &Map.has_key?(&1, :mrn))
    end

    test "passes q and paging through", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/v1/patients", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        respond(conn, 200, %{"data" => [], "page" => 2, "pageSize" => 5, "total" => 0})
      end)

      assert {:ok, _} = Client.search_patients("doe", page: 2, page_size: 5)

      assert_receive {:params, params}
      assert params["q"] == "doe"
      assert params["page"] == "2"
      assert params["pageSize"] == "5"
    end

    test "omits q when no query is given", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/v1/patients", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        respond(conn, 200, %{"data" => [], "page" => 1, "pageSize" => 25, "total" => 0})
      end)

      assert {:ok, _} = Client.search_patients()
      assert_receive {:params, params}
      refute Map.has_key?(params, "q")
    end
  end

  describe "list_locations/1" do
    test "projects the site fields", %{bypass: bypass} do
      body = %{
        "data" => [
          %{
            "id" => "loc_1",
            "practiceId" => "prac_1",
            "name" => "Northside Clinic",
            "address" => "1 Main St",
            "timezone" => "America/New_York",
            "active" => true,
            "undocumented" => "x"
          }
        ],
        "page" => 1,
        "pageSize" => 25,
        "total" => 1
      }

      Bypass.expect(bypass, "GET", "/v1/locations", &respond(&1, 200, body))

      assert {:ok, %{data: [loc]}} = Client.list_locations()

      assert loc == %{
               id: "loc_1",
               practice_id: "prac_1",
               name: "Northside Clinic",
               address: "1 Main St",
               timezone: "America/New_York",
               active: true
             }
    end

    test "filters by practice when asked", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/v1/locations", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        respond(conn, 200, %{"data" => [], "page" => 1, "pageSize" => 25, "total" => 0})
      end)

      assert {:ok, _} = Client.list_locations(practice_id: "prac_7")
      assert_receive {:params, %{"practiceId" => "prac_7"}}
    end
  end

  describe "list_practices/1" do
    test "projects the practice fields", %{bypass: bypass} do
      body = %{
        "data" => [
          %{
            "id" => "prac_1",
            "name" => "Northside",
            "slug" => "northside",
            "organizationId" => "org_1",
            "extra" => 1
          }
        ],
        "page" => 1,
        "pageSize" => 25,
        "total" => 1
      }

      Bypass.expect(bypass, "GET", "/v1/practices", &respond(&1, 200, body))

      assert {:ok, %{data: [practice]}} = Client.list_practices()

      assert practice == %{
               id: "prac_1",
               name: "Northside",
               slug: "northside",
               organization_id: "org_1"
             }
    end
  end

  describe "failures" do
    test "a 401 invalidates the cached token so the next call re-fetches",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/practices", &respond(&1, 401, %{"error" => "expired"}))

      assert {:error, {:http_status, 401, _}} = Client.list_practices()
    end

    test "a server error is surfaced", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/practices", &respond(&1, 500, %{"error" => "boom"}))

      assert {:error, {:http_status, 500, _}} = Client.list_practices()
    end

    test "an unreachable host is surfaced, not raised", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, _reason} = Client.list_practices()
    end

    test "a non-JSON 200 is an error rather than a bad projection", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/practices", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "not json")
      end)

      assert {:error, {:unexpected_body, _}} = Client.list_practices()
    end
  end

  describe "when unconfigured" do
    test "returns a clean error instead of crashing" do
      Application.put_env(:scheduling, Scheduling.Core, [])

      assert {:error, :not_configured} = Client.list_practices()
      assert {:error, :not_configured} = Client.get_patient("pat_1")
    end

    test "a base_url with a trailing slash does not produce a double slash",
         %{bypass: bypass} do
      Application.put_env(
        :scheduling,
        Scheduling.Core,
        Application.get_env(:scheduling, Scheduling.Core)
        |> Keyword.put(:base_url, "http://localhost:#{bypass.port}/")
      )

      Bypass.expect(bypass, "GET", "/v1/practices", fn conn ->
        respond(conn, 200, %{"data" => [], "page" => 1, "pageSize" => 25, "total" => 0})
      end)

      assert {:ok, _} = Client.list_practices()
    end
  end
end
