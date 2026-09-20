defmodule SchedulingWeb.Plugs.IdempotencyTest do
  @moduledoc """
  Retrying a write must not perform it twice.

  A check-in bridge whose request times out cannot tell whether the patient was
  signed in. Retrying risks two queue entries for one arrival; not retrying
  risks none. Both are wrong in front of a waiting room — so the caller repeats
  the request with the same `Idempotency-Key` and gets the first call's
  response back, id included.

  The assertion that matters throughout is not "the same JSON came back" but
  **"the row was created once"**. A cache that returns the right body while
  still writing twice would pass the first and fail the patient.
  """
  use SchedulingWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Scheduling.Idempotency
  alias Scheduling.Idempotency.Key
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo
  alias Scheduling.Visits.Visit

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Idempotent Patient"}))
  end

  defp post_visit(patient, opts \\ []) do
    conn = build_conn()

    conn =
      case Keyword.get(opts, :key) do
        nil -> conn
        key -> put_req_header(conn, "idempotency-key", key)
      end

    post(conn, ~p"/api/v1/visits", visit: %{patient_id: patient.id})
  end

  defp visit_count, do: Repo.aggregate(Visit, :count)

  describe "without the header" do
    test "nothing is recorded and the write is untouched" do
      patient = patient_fixture()

      assert json_response(post_visit(patient), 201)
      assert Repo.aggregate(Key, :count) == 0
      assert visit_count() == 1
    end

    test "two identical calls create two visits — which is the point of the header" do
      # Establishes that the protection is opt-in and that these tests are
      # observing it, not observing some other uniqueness constraint.
      patient = patient_fixture()

      assert json_response(post_visit(patient), 201)
      assert json_response(post_visit(patient), 201)
      assert visit_count() == 2
    end
  end

  describe "with the same key twice" do
    test "the write happens once and the first response is returned" do
      patient = patient_fixture()

      first = post_visit(patient, key: "arrival-001")
      body = json_response(first, 201)

      second = post_visit(patient, key: "arrival-001")

      assert json_response(second, 201) == body
      assert visit_count() == 1
    end

    test "the replay is labelled, so a caller can tell it apart" do
      patient = patient_fixture()

      post_visit(patient, key: "arrival-002")
      replayed = post_visit(patient, key: "arrival-002")

      assert get_resp_header(replayed, "idempotency-replayed") == ["true"]
    end

    test "a fresh response is not labelled" do
      patient = patient_fixture()

      assert get_resp_header(post_visit(patient, key: "arrival-003"), "idempotency-replayed") ==
               []
    end
  end

  describe "the same key on a different request" do
    test "is refused rather than silently answered with the wrong response" do
      # The failure this catches: a caller recycling a key would otherwise
      # receive the cached response for something else entirely, and believe
      # it described their new request.
      one = patient_fixture()
      other = patient_fixture()

      assert json_response(post_visit(one, key: "recycled"), 201)

      assert %{"error" => %{"code" => "idempotency_key_reuse"}} =
               json_response(post_visit(other, key: "recycled"), 422)

      assert visit_count() == 1
    end

    test "field order in the body is not a difference" do
      # A client that does not preserve key order is sending the same request.
      # Rejecting it would break a legitimate retry.
      patient = patient_fixture()

      first =
        build_conn()
        |> put_req_header("idempotency-key", "ordered")
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id, "extra" => nil}})

      second =
        build_conn()
        |> put_req_header("idempotency-key", "ordered")
        |> post(~p"/api/v1/visits", %{"visit" => %{"extra" => nil, "patient_id" => patient.id}})

      assert second.status == first.status
      assert visit_count() == 1
    end
  end

  describe "a claim that has not settled" do
    test "answers 409 rather than letting a concurrent duplicate through" do
      # Simulates the in-flight case directly: a claim row with no response is
      # what a request mid-handler leaves behind.
      patient = patient_fixture()

      # Must be the fingerprint the real request will produce — a mismatched
      # one is a different case entirely, and takes precedence deliberately:
      # "you reused a key" is actionable, "wait and retry" is not.
      fingerprint =
        Idempotency.fingerprint("POST", "/api/v1/visits", %{
          "visit" => %{"patient_id" => patient.id}
        })

      {:claimed, _} = Idempotency.claim("anonymous", "in-flight", fingerprint)

      conn =
        build_conn()
        |> put_req_header("idempotency-key", "in-flight")
        |> post(~p"/api/v1/visits", visit: %{patient_id: patient.id})

      assert %{"error" => %{"code" => "idempotency_key_in_progress"}} = json_response(conn, 409)
      assert visit_count() == 0
    end
  end

  describe "keys are scoped to the caller" do
    test "two callers may use the same key independently" do
      # Callers generate their own keys. Two services choosing the same UUID
      # must not collide, and neither may read back the other's response.
      patient = patient_fixture()
      {:claimed, claimed} = Idempotency.claim("service:other-bridge", "shared", "fp")
      Idempotency.settle(claimed, 201, ~s({"id":"theirs"}), "application/json")

      conn =
        build_conn()
        |> put_req_header("idempotency-key", "shared")
        |> post(~p"/api/v1/visits", visit: %{patient_id: patient.id})

      # Ours ran for real rather than replaying theirs.
      refute json_response(conn, 201)["id"] == "theirs"
      assert visit_count() == 1
    end
  end

  describe "a malformed header" do
    test "is refused rather than ignored" do
      # Silently ignoring it would leave a caller believing they had retry
      # protection they do not have.
      patient = patient_fixture()

      conn =
        build_conn()
        |> put_req_header("idempotency-key", String.duplicate("x", 300))
        |> post(~p"/api/v1/visits", visit: %{patient_id: patient.id})

      assert %{"error" => %{"code" => "idempotency_key_invalid"}} = json_response(conn, 422)
      assert visit_count() == 0
    end
  end

  describe "retention" do
    test "delete_expired/0 removes keys past the window and leaves fresh ones" do
      {:claimed, old} = Idempotency.claim("anonymous", "old", "fp1")
      {:claimed, _fresh} = Idempotency.claim("anonymous", "fresh", "fp2")

      stale = DateTime.add(DateTime.utc_now(), -(Idempotency.retention_hours() + 1), :hour)
      Repo.update_all(from(k in Key, where: k.id == ^old.id), set: [inserted_at: stale])

      assert Idempotency.delete_expired() == 1
      assert Repo.aggregate(Key, :count) == 1
    end

    test "an abandoned claim is swept, so the key becomes usable again" do
      # A request that died between claiming and settling would otherwise
      # answer 409 to every retry forever.
      {:claimed, abandoned} = Idempotency.claim("anonymous", "abandoned", "fp")
      refute Key.settled?(abandoned)

      stale = DateTime.add(DateTime.utc_now(), -(Idempotency.retention_hours() + 1), :hour)
      Repo.update_all(from(k in Key, where: k.id == ^abandoned.id), set: [inserted_at: stale])

      assert Idempotency.delete_expired() == 1
      assert {:claimed, _} = Idempotency.claim("anonymous", "abandoned", "fp")
    end
  end
end
