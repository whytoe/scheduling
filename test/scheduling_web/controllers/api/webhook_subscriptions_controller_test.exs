defmodule SchedulingWeb.Api.WebhookSubscriptionControllerTest do
  use SchedulingWeb.ConnCase, async: true

  describe "POST /api/v1/webhook_subscriptions" do
    test "creates a subscription and returns the secret in the response", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/webhook_subscriptions",
          webhook_subscription: %{
            url: "https://example.test/hook",
            event_types: ["visit.created", "visit.ended"],
            description: "monitoring sink"
          }
        )

      body = json_response(conn, 201)
      assert body["url"] == "https://example.test/hook"
      assert body["event_types"] == ["visit.created", "visit.ended"]
      assert body["active"] == true
      assert is_binary(body["secret"])
    end

    test "rejects a non-http URL", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/webhook_subscriptions",
          webhook_subscription: %{url: "ftp://example.test"}
        )

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => fields}}} =
               json_response(conn, 422)

      assert "must be a valid http(s) URL" in fields["url"]
    end
  end

  describe "GET /api/v1/webhook_subscriptions/:id" do
    test "show does NOT include the secret", %{conn: conn} do
      create =
        post(conn, ~p"/api/v1/webhook_subscriptions",
          webhook_subscription: %{url: "https://example.test/hook"}
        )

      %{"id" => id, "secret" => _} = json_response(create, 201)

      conn = build_conn() |> get(~p"/api/v1/webhook_subscriptions/#{id}")
      body = json_response(conn, 200)
      assert body["id"] == id
      refute Map.has_key?(body, "secret")
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/webhook_subscriptions/99999")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/webhook_subscriptions/:id" do
    test "updates event_types and active", %{conn: conn} do
      %{"id" => id} =
        post(conn, ~p"/api/v1/webhook_subscriptions",
          webhook_subscription: %{url: "https://example.test/hook"}
        )
        |> json_response(201)

      conn =
        build_conn()
        |> patch(~p"/api/v1/webhook_subscriptions/#{id}",
          webhook_subscription: %{event_types: ["queue_entry.completed"], active: false}
        )

      assert %{"active" => false, "event_types" => ["queue_entry.completed"]} =
               json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/webhook_subscriptions/:id" do
    test "204 then 404", %{conn: conn} do
      %{"id" => id} =
        post(conn, ~p"/api/v1/webhook_subscriptions",
          webhook_subscription: %{url: "https://example.test/hook"}
        )
        |> json_response(201)

      assert response(delete(build_conn(), ~p"/api/v1/webhook_subscriptions/#{id}"), 204)
      conn = build_conn() |> get(~p"/api/v1/webhook_subscriptions/#{id}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /api/v1/webhook_subscriptions/:id/test" do
    test "fires a test delivery and reports the receiver's status", %{conn: conn} do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "POST", "/hook", fn c -> Plug.Conn.resp(c, 200, "ok") end)

      {:ok, sub} =
        Scheduling.Webhooks.create_subscription(%{url: "http://localhost:#{bypass.port}/hook"})

      body = conn |> post(~p"/api/v1/webhook_subscriptions/#{sub.id}/test") |> json_response(200)

      assert body["delivered"] == true
      assert body["response_status"] == 200
    end

    test "reports delivered=false on a non-2xx", %{conn: conn} do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "POST", "/hook", fn c -> Plug.Conn.resp(c, 500, "boom") end)

      {:ok, sub} =
        Scheduling.Webhooks.create_subscription(%{url: "http://localhost:#{bypass.port}/hook"})

      body = conn |> post(~p"/api/v1/webhook_subscriptions/#{sub.id}/test") |> json_response(200)

      assert body["delivered"] == false
      assert body["response_status"] == 500
    end

    test "404 for an unknown subscription", %{conn: conn} do
      assert %{"error" => %{"code" => "not_found"}} =
               conn |> post(~p"/api/v1/webhook_subscriptions/99999/test") |> json_response(404)
    end
  end
end
