defmodule SchedulingWeb.Api.WebhookDeliveryControllerTest do
  @moduledoc "GET /api/v1/webhook_deliveries — operator observability + DLQ view (sc-6ub)."
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Repo
  alias Scheduling.Webhooks
  alias Scheduling.Webhooks.Delivery

  defp subscription do
    {:ok, sub} = Webhooks.create_subscription(%{url: "https://example.test/hook"})
    sub
  end

  defp delivery(sub, attrs) do
    Repo.insert!(
      Delivery.changeset(
        %Delivery{},
        Map.merge(
          %{
            subscription_id: sub.id,
            event_type: "visit.created",
            body: "{}",
            status: :pending,
            attempts: 0
          },
          attrs
        )
      )
    )
  end

  test "lists deliveries, newest first", %{conn: conn} do
    sub = subscription()
    delivery(sub, %{status: :delivered, attempts: 1, last_response_status: 200})
    delivery(sub, %{status: :dead, attempts: 5, last_error: "boom"})

    body = conn |> get(~p"/api/v1/webhook_deliveries") |> json_response(200)
    assert length(body) == 2
    assert Enum.map(body, & &1["status"]) |> Enum.sort() == ["dead", "delivered"]
    assert Enum.all?(body, &(&1["subscription_id"] == sub.id))
  end

  test "filters by status (the dead-letter queue)", %{conn: conn} do
    sub = subscription()
    delivery(sub, %{status: :delivered, attempts: 1})
    delivery(sub, %{status: :dead, attempts: 5, last_error: "boom"})

    body = conn |> get(~p"/api/v1/webhook_deliveries?status=dead") |> json_response(200)
    assert [d] = body
    assert d["status"] == "dead"
    assert d["last_error"] == "boom"
  end

  test "filters by subscription_id", %{conn: conn} do
    a = subscription()
    b = subscription()
    delivery(a, %{status: :delivered, attempts: 1})
    delivery(b, %{status: :pending})

    body =
      conn |> get(~p"/api/v1/webhook_deliveries?subscription_id=#{a.id}") |> json_response(200)

    assert [d] = body
    assert d["subscription_id"] == a.id
  end
end
