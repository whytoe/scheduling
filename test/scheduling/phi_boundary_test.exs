defmodule Scheduling.PhiBoundaryTest do
  @moduledoc """
  Scheduling carries PII but not health data (`docs/data-boundary.md`).

  `docs/integrations.md` names three places a clinical detail could escape:
  the `routing_decisions` audit log, `visit_events`, and every outbound
  webhook. This asserts the boundary holds at each of them, so a future change
  that reintroduces a leak fails here rather than in production.

  `async: false` — the webhook and compliance tests mutate application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Audit
  alias Scheduling.Catalog
  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Webhooks

  @patient_uuid "33333333-3333-3333-3333-333333333333"
  @reference "enc_01HV3K7Q"

  # The kind of string that must never appear in an egress path: a form type
  # naming a clinical purpose.
  @clinical_marker "stroke-consent"

  defp patient_fixture do
    Repo.insert!(
      Patient.changeset(%Patient{}, %{name: "Boundary Test", intake_patient_id: @patient_uuid})
    )
  end

  defp capability_fixture do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "CT-#{System.unique_integer([:positive])}"})

    cap
  end

  describe "the schema itself" do
    test "a queue entry has no diagnosis association" do
      fields = QueueEntry.__schema__(:fields)
      assocs = QueueEntry.__schema__(:associations)

      refute :diagnosis_id in fields
      refute :diagnosis in assocs
    end

    test "a queue entry carries an opaque compliance reference instead" do
      assert :compliance_ref in QueueEntry.__schema__(:fields)
    end
  end

  describe "visit_events" do
    test "the queue_entry.created payload carries no clinical field" do
      cap = capability_fixture()

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "priority" => 3,
          "required_capability_ids" => [cap.id],
          "compliance_ref" => @reference
        })

      assert [event] = Audit.list_events(type: "queue_entry.created")
      assert event.queue_entry_id == entry.id
      # Priority and nothing else. Notably not the diagnosis that produced the
      # capability set, and not the compliance reference.
      assert Map.keys(event.payload) == ["priority"]
    end
  end

  describe "routing_decisions" do
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

    test "a compliance block records the reference, never the form types",
         %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/v1/compliance/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"compliant" => false}))
      end)

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "compliance_ref" => @reference
        })

      assert {:compliance_failed, @reference} = Queue.accept(Queue.get_entry!(entry.id))

      assert [decision] = Audit.list_decisions()
      assert decision.rationale =~ "Compliance check failed"
      assert decision.rationale =~ @reference
      refute decision.rationale =~ @clinical_marker

      # The prefix the /decisions outcome filter keys off must survive.
      assert String.starts_with?(decision.rationale, "Compliance check failed")
    end
  end

  describe "outbound webhooks" do
    setup do
      original = Application.get_env(:scheduling, :webhooks_enabled)
      Application.put_env(:scheduling, :webhooks_enabled, true)
      on_exit(fn -> Application.put_env(:scheduling, :webhooks_enabled, original) end)
      :ok
    end

    test "a delivered event body carries no clinical field" do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.expect(bypass, "POST", "/hook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:delivered, body})
        Plug.Conn.resp(conn, 200, "")
      end)

      {:ok, sub} =
        Webhooks.create_subscription(%{
          url: "http://localhost:#{bypass.port}/hook",
          event_types: ["queue_entry.created"]
        })

      cap = capability_fixture()

      {:ok, _entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_capability_ids" => [cap.id],
          "compliance_ref" => @reference
        })

      assert [event] = Audit.list_events(type: "queue_entry.created")
      assert {:ok, 200} = Webhooks.deliver(sub, event)

      assert_receive {:delivered, body}
      decoded = Jason.decode!(body)

      # The widest egress path in the system. It may name ids and the actor;
      # it may not describe why the patient is here.
      refute body =~ @clinical_marker
      refute Map.has_key?(decoded, "diagnosis_id")
      refute Map.has_key?(decoded["payload"], "diagnosis_id")
      assert Map.keys(decoded["payload"]) == ["priority"]
    end
  end
end
