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

  # A stand-in for an intake that behaves correctly on the self-check: it
  # answers 400 for a `cref_` it has never minted, and answers the control
  # query that follows. `fun` therefore sees only the queries the gate makes
  # about a patient, so the tests below that count or inspect requests are not
  # reading the self-check's.
  #
  # The tests that are *about* the self-check install their own handler.
  defp stub_responses(bypass, fun) do
    Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["compliance_ref"] do
        ref when ref in [@ref_a, @ref_b] -> fun.(conn)
        # The control query, which carries no reference at all.
        nil -> respond(conn, 200, [])
        # A reference intake never issued.
        _unminted -> respond(conn, 400, %{"error" => "unknown_reference"})
      end
    end)
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

      # The body is deliberately absent — see sc-87w. It used to ride in this
      # tuple and be inspected into routing_decisions.rationale, which is
      # append-only and readable by any token with a read role.
      assert {:error, {:http_status, 500}} = Compliance.verify(entry(patient_fixture()))
    end

    test "a body that is not a list of responses is an error", %{bypass: bypass} do
      stub_responses(bypass, &respond(&1, 200, %{"status" => "maybe"}))

      assert {:error, {:unexpected_body, _}} = Compliance.verify(entry(patient_fixture()))
    end

    test "an unreachable intake is an error", %{bypass: bypass} do
      # Now caught by the self-check rather than by the per-reference query:
      # an intake that cannot answer "is this a real reference" cannot be shown
      # to be filtering either, and the gate refuses before it asks about a
      # patient. Either way the accept fails closed.
      Bypass.down(bypass)

      assert {:error, {:ref_filter_unverified, {:probe_transport, _}}} =
               Compliance.verify(entry(patient_fixture()))
    end
  end

  # ---------------------------------------------------------------------------
  # The self-check. `satisfied_refs/2` reads only the row count, so an intake
  # that accepts `compliance_ref` and ignores it would answer every query with
  # "yes, this patient has completed something" and pass everyone. These tests
  # are what stand between that and production.
  # ---------------------------------------------------------------------------
  describe "proving intake filters by compliance_ref" do
    # Answers every query with a completed response — the shape of an intake
    # that ignores `compliance_ref` entirely.
    defp stub_ignoring_intake(bypass, test_pid \\ nil) do
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        if test_pid, do: send(test_pid, {:asked, conn.query_params})
        respond(conn, 200, a_completed_response())
      end)
    end

    test "rows for a reference that cannot exist means the gate refuses to run",
         %{bypass: bypass} do
      # The whole point. Without the check this is `:ok` — the patient's
      # unrelated completed form satisfies a requirement it has nothing to do
      # with, and nothing anywhere says so.
      stub_ignoring_intake(bypass)

      assert Compliance.verify(entry(patient_fixture())) ==
               {:error, {:ref_filter_unverified, :ref_filter_not_applied}}
    end

    test "a refusal is an error, never a verdict about the patient", %{bypass: bypass} do
      # It must not surface as {:blocked, _}: the patient is not the problem,
      # and the accept flow renders the two differently (503 vs 422).
      stub_ignoring_intake(bypass)

      assert {:error, _} = Compliance.verify(entry(patient_fixture()))
    end

    test "400 for the unminted reference, answered control, and the gate runs",
         %{bypass: bypass} do
      # The behaviour settled in the sc-s9x exchange: intake refuses to resolve
      # a reference it never issued. That is proof the parameter reached a
      # lookup, so the gate proceeds and reaches a real verdict.
      stub_responses(bypass, &respond(&1, 200, []))

      assert Compliance.verify(entry(patient_fixture())) == {:blocked, [@ref_a]}
    end

    test "an empty answer to the unminted reference is accepted as consistent",
         %{bypass: bypass} do
      # Weaker evidence than the 400 — an intake holding no completed responses
      # at all answers identically — but not evidence of failure, and the
      # failure it could mask blocks rather than passes.
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["compliance_ref"] do
          @ref_a -> respond(conn, 200, a_completed_response())
          _ -> respond(conn, 200, [])
        end
      end)

      assert Compliance.verify(entry(patient_fixture())) == :ok
    end

    test "a 400 that is not about the reference proves nothing, so the gate refuses",
         %{bypass: bypass} do
      # An intake that rejects the query for some other reason — it demands a
      # patient_id, say — would 400 the probe too. Reading that as "the filter
      # is live" would be exactly the kind of reassuring-but-empty signal this
      # check exists to stop, so the same query is repeated without the
      # reference and a second 400 settles it.
      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        respond(conn, 400, %{"error" => "patient_id is required"})
      end)

      assert Compliance.verify(entry(patient_fixture())) ==
               {:error, {:ref_filter_unverified, :probe_inconclusive}}
    end

    test "the probe sends no patient id — a second filter would mask the first",
         %{bypass: bypass} do
      test_pid = self()
      stub_ignoring_intake(bypass, test_pid)

      Compliance.verify(entry(patient_fixture()))

      assert_receive {:asked, params}
      refute Map.has_key?(params, "patient_id")
      assert params["compliance_ref"] =~ ~r/^cref_[a-f0-9]{12}$/
      assert params["status"] == "completed"
    end

    test "a refusal is not cached — the next accept asks again", %{bypass: bypass} do
      # An intake that ships the filter must start working without a restart
      # here. Two verifies, two probes.
      test_pid = self()
      stub_ignoring_intake(bypass, test_pid)

      patient = patient_fixture()
      assert {:error, _} = Compliance.verify(entry(patient))
      assert {:error, _} = Compliance.verify(entry(patient))

      assert_receive {:asked, _}
      assert_receive {:asked, _}
    end

    test "a verified answer is reused rather than re-established per accept",
         %{bypass: bypass} do
      # Per-request was the alternative, and it doubles our traffic to intake to
      # re-establish a fact that does not move between two accepts.
      test_pid = self()

      Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["compliance_ref"] do
          @ref_a ->
            respond(conn, 200, a_completed_response())

          nil ->
            respond(conn, 200, [])

          _unminted ->
            send(test_pid, :probed)
            respond(conn, 400, %{"error" => "unknown_reference"})
        end
      end)

      patient = patient_fixture()
      assert Compliance.verify(entry(patient)) == :ok
      assert Compliance.verify(entry(patient)) == :ok
      assert Compliance.verify(entry(patient)) == :ok

      assert_receive :probed
      refute_receive :probed, 200
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
