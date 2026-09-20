defmodule Scheduling.ComplianceRationalePhiTest do
  @moduledoc """
  Nothing intake sends may reach a routing-decision rationale.

  `routing_decisions.rationale` is append-only, rendered at `/decisions`, and
  returned by `GET /api/v1/routing_decisions` to any token with a read role —
  `viewer` and `service` included. A body from intake's `/responses` is a
  patient's form-response rows.

  The client used to carry that body in its error reason and `Queue` used to
  `inspect/1` the reason into the rationale, which put health data into a row
  that cannot be edited or deleted. This asserts both halves of the fix: the
  client no longer carries it, and the sink no longer trusts an arbitrary term.

  `async: false` — points `Scheduling.Compliance` at a Bypass server, which is
  application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Audit
  alias Scheduling.Compliance.Client
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  # Something unmistakable, so a leak cannot be mistaken for coincidence.
  @patient_content "Wolfeschlegelsteinhausenbergerdorff"

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:scheduling, Scheduling.Compliance)

    Application.put_env(:scheduling, Scheduling.Compliance,
      base_url: "http://localhost:#{bypass.port}/api/v1",
      api_key: "test-key",
      http_timeout_ms: 500,
      required_compliance_refs: []
    )

    on_exit(fn -> Application.put_env(:scheduling, Scheduling.Compliance, original) end)

    %{bypass: bypass}
  end

  # The probe carries no patient_id and the real query always does — see
  # Client.probe_ref_filter/0. That is what lets one stub answer both: the
  # probe honestly (so the gate proceeds) and the real query with a body it
  # must not repeat.
  defp stub_probe_ok_then_fail(bypass, status, body) do
    Bypass.stub(bypass, "GET", "/api/v1/responses", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "patient_id") do
        Plug.Conn.resp(conn, status, body)
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
      end
    end)
  end

  defp entry_with_ref(ref) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2
      })

    # The gate only asks intake when it can correlate a patient — see
    # Compliance.verify/1. Without this the whole path is skipped.
    patient =
      Repo.insert!(
        Patient.changeset(%Patient{}, %{
          name: "Gate Patient",
          intake_patient_id: Ecto.UUID.generate()
        })
      )

    {:ok, entry} =
      Queue.create_entry(%{
        "patient_id" => patient.id,
        "required_compliance_refs" => [ref]
      })

    {office, entry}
  end

  defp rationales do
    Audit.list_decisions(%{}) |> Enum.map(& &1.rationale)
  end

  describe "the client" do
    test "does not carry a 200 body it cannot parse", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/responses", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"surprise" => @patient_content}))
      end)

      assert {:error, reason} = Client.satisfied_refs("p1", ["cref_abc123"])
      refute inspect(reason) =~ @patient_content
      assert {:unexpected_body, {:map, 1}} = reason
    end

    test "does not carry a non-200 body", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/responses", fn conn ->
        Plug.Conn.resp(conn, 500, Jason.encode!(%{"rows" => [@patient_content]}))
      end)

      assert {:error, reason} = Client.satisfied_refs("p1", ["cref_abc123"])
      refute inspect(reason) =~ @patient_content
      assert reason == {:http_status, 500}
    end
  end

  describe "the audit row" do
    test "carries no intake content when the gate cannot run", %{bypass: bypass} do
      stub_probe_ok_then_fail(bypass, 500, Jason.encode!(%{"rows" => [@patient_content]}))

      {_office, entry} = entry_with_ref("cref_leaky")
      Queue.accept(Queue.get_entry!(entry.id))

      written = rationales()
      assert written != [], "expected a routing decision to have been recorded"

      for rationale <- written do
        refute rationale =~ @patient_content
      end
    end

    test "still says enough to diagnose", %{bypass: bypass} do
      # Stripping content must not strip meaning. An operator needs to know
      # intake was reachable and unhappy, not merely that something failed.
      stub_probe_ok_then_fail(bypass, 503, "unavailable")

      {_office, entry} = entry_with_ref("cref_diag")
      Queue.accept(Queue.get_entry!(entry.id))

      assert Enum.any?(rationales(), &(&1 =~ "intake answered 503"))
    end
  end
end
