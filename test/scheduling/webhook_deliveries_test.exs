defmodule Scheduling.WebhookDeliveriesTest do
  @moduledoc """
  The durability layer under webhook fan-out: dispatch enqueues, the sweeper's
  deliver_due/1 sends, failures retry on a backoff, exhaustion dead-letters, and
  a persistently-dead endpoint auto-disables its subscription (sc-6ub).
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Webhooks

  setup do
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  # Merge over the test config (which already sets sweeper_enabled: false) so we
  # keep the sweeper off while overriding backoff/limits for a deterministic run.
  defp configure(overrides) do
    existing = Application.get_env(:scheduling, Webhooks, [])
    Application.put_env(:scheduling, Webhooks, Keyword.merge(existing, overrides))
    on_exit(fn -> Application.put_env(:scheduling, Webhooks, existing) end)
  end

  defp sub_at(bypass) do
    {:ok, sub} =
      Webhooks.create_subscription(%{
        url: "http://localhost:#{bypass.port}/hook",
        event_types: ["visit.created"]
      })

    sub
  end

  defp event(id \\ 1) do
    %{
      id: id,
      type: "visit.created",
      visit_id: 1,
      patient_id: 1,
      payload: %{},
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp only_delivery(sub_id) do
    assert [d] = Webhooks.list_deliveries(subscription_id: sub_id)
    d
  end

  describe "dispatch enqueues" do
    test "writes one pending, due delivery per matching subscription", %{bypass: bypass} do
      sub = sub_at(bypass)

      :ok = Webhooks.dispatch(event())

      d = only_delivery(sub.id)
      assert d.status == :pending
      assert d.attempts == 0
      assert d.event_type == "visit.created"
      assert d.event_id == 1
      refute is_nil(d.next_retry_at)
    end

    test "does not enqueue for a subscription that does not match the type", %{bypass: bypass} do
      {:ok, other} =
        Webhooks.create_subscription(%{
          url: "http://localhost:#{bypass.port}/x",
          event_types: ["queue_entry.completed"]
        })

      :ok = Webhooks.dispatch(event())
      assert Webhooks.list_deliveries(subscription_id: other.id) == []
    end
  end

  describe "deliver_due — success" do
    test "a 2xx marks the delivery delivered", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/hook", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())

      assert Webhooks.deliver_due() == 1

      d = only_delivery(sub.id)
      assert d.status == :delivered
      assert d.attempts == 1
      assert d.last_response_status == 200
      refute is_nil(d.delivered_at)
      assert is_nil(d.next_retry_at)
    end

    test "success resets the subscription's consecutive-failure count", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      sub = sub_at(bypass)
      sub |> Ecto.Changeset.change(consecutive_failures: 3) |> Repo.update!()
      Webhooks.dispatch(event())

      Webhooks.deliver_due()

      assert Webhooks.get_subscription!(sub.id).consecutive_failures == 0
    end
  end

  describe "deliver_due — failure and retry" do
    test "a non-2xx schedules a retry and bumps the failure count", %{bypass: bypass} do
      configure(backoff_seconds: [0], max_attempts: 3)
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "boom") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())

      Webhooks.deliver_due()

      d = only_delivery(sub.id)
      assert d.status == :pending
      assert d.attempts == 1
      assert d.last_response_status == 500
      refute is_nil(d.next_retry_at)
      assert Webhooks.get_subscription!(sub.id).consecutive_failures == 1
    end

    test "a transport error is recorded as last_error, not a response status", %{bypass: bypass} do
      configure(backoff_seconds: [0], max_attempts: 3)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())
      Bypass.down(bypass)

      Webhooks.deliver_due()

      d = only_delivery(sub.id)
      assert d.status == :pending
      assert d.attempts == 1
      assert is_nil(d.last_response_status)
      refute is_nil(d.last_error)
    end

    test "a retry scheduled in the future is not picked up early", %{bypass: bypass} do
      configure(backoff_seconds: [3600], max_attempts: 3)
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "boom") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())

      assert Webhooks.deliver_due() == 1
      # next_retry_at is an hour out, so a second drain does nothing.
      assert Webhooks.deliver_due() == 0
      assert only_delivery(sub.id).attempts == 1
    end
  end

  describe "deliver_due — dead-letter and auto-disable" do
    test "a delivery is dead-lettered once attempts reach max_attempts", %{bypass: bypass} do
      configure(backoff_seconds: [0], max_attempts: 2)
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "boom") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())

      Webhooks.deliver_due()
      Webhooks.deliver_due()

      d = only_delivery(sub.id)
      assert d.status == :dead
      assert d.attempts == 2
      # A dead delivery is no longer due.
      assert Webhooks.deliver_due() == 0
    end

    test "a subscription auto-disables after enough consecutive failures", %{bypass: bypass} do
      configure(backoff_seconds: [0], max_attempts: 5, auto_disable_after: 2)
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "boom") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event())

      Webhooks.deliver_due()
      Webhooks.deliver_due()

      reloaded = Webhooks.get_subscription!(sub.id)
      assert reloaded.active == false
      assert reloaded.consecutive_failures == 2
    end
  end

  describe "list_deliveries" do
    test "filters by status", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      sub = sub_at(bypass)
      Webhooks.dispatch(event(1))
      Webhooks.deliver_due()

      assert [d] = Webhooks.list_deliveries(subscription_id: sub.id, status: "delivered")
      assert d.status == :delivered
      assert Webhooks.list_deliveries(subscription_id: sub.id, status: "dead") == []
    end
  end
end
