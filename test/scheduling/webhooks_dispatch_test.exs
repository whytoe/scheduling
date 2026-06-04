defmodule Scheduling.WebhooksDispatchTest do
  @moduledoc """
  Exercises the synchronous delivery path (`Scheduling.Webhooks.deliver/2`)
  against a Bypass server. The async fan-out (`dispatch/1` via `Task.start`)
  isn't tested here — we'd be racing a fire-and-forget Task. Delivery
  semantics live in `deliver/2`, and Audit.record_event invokes
  Webhooks.dispatch which fans out via deliver. Testing deliver is enough
  to lock the contract.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Webhooks
  alias Scheduling.Webhooks.Subscription

  setup do
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  defp subscription_at(bypass, secret) do
    {:ok, sub} =
      Webhooks.create_subscription(%{
        url: "http://localhost:#{bypass.port}/hook",
        secret: secret,
        event_types: ["visit.created"]
      })

    sub
  end

  defp event(extras \\ %{}) do
    Map.merge(
      %{
        id: 99,
        type: "visit.created",
        visit_id: 1,
        patient_id: 1,
        payload: %{},
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      extras
    )
  end

  test "deliver posts a signed payload to the subscription URL", %{bypass: bypass} do
    secret = "delivery-secret-1234567890abcdef"
    sub = subscription_at(bypass, secret)
    parent = self()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:got, body, conn.req_headers})
      Plug.Conn.resp(conn, 200, "")
    end)

    assert {:ok, 200} = Webhooks.deliver(sub, event())

    assert_received {:got, body, headers}

    # Body decodes back to JSON with the event fields we set
    parsed = Jason.decode!(body)
    assert parsed["type"] == "visit.created"
    assert parsed["id"] == 99
    assert parsed["visit_id"] == 1

    # Required headers are present
    header_map = Map.new(headers)
    assert header_map["content-type"] == "application/json"
    assert header_map["x-scheduling-event-type"] == "visit.created"

    ts = header_map["x-scheduling-timestamp"]
    signature = header_map["x-scheduling-signature"]

    # Signature verifies against the raw body we received
    assert :ok = Webhooks.verify_signature(signature, ts, body, secret)
  end

  test "deliver surfaces a non-2xx status", %{bypass: bypass} do
    sub = subscription_at(bypass, "any-secret-1234567890abcdef")

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:ok, 500} = Webhooks.deliver(sub, event())
  end

  test "deliver returns a transport error when the URL is unreachable" do
    sub = %Subscription{
      url: "http://localhost:1/never",
      secret: "never-secret-1234567890abcdef",
      event_types: ["visit.created"]
    }

    assert {:error, %Req.TransportError{}} = Webhooks.deliver(sub, event())
  end
end
