defmodule SchedulingWeb.Plugs.ApiAuthTest do
  @moduledoc """
  End-to-end coverage of `/api/v1` authentication and role authorization,
  driven through the router with real tokens from the fake provider in
  `Scheduling.OidcProvider`.

  `async: false` — pointing `Scheduling.Auth` at the fake provider writes
  application env, which is global.
  """
  use SchedulingWeb.ConnCase, async: false

  import Scheduling.OidcProvider

  alias Scheduling.Audit
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo
  alias Scheduling.Visits.Visit

  setup :setup_oidc_provider

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Jane Doe"}))
  end

  describe "authentication" do
    test "a request with no token is refused", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/offices")

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(Bearer realm="scheduling")
    end

    test "a non-Bearer Authorization header is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(~p"/api/v1/offices")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "an empty Bearer value is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer   ")
        |> get(~p"/api/v1/offices")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a forged token is refused as invalid, not merely unauthorized", ctx do
      forged = access_token(ctx, %{}, jwk: JOSE.JWK.generate_key({:rsa, 2048}))
      conn = ctx.conn |> with_bearer(forged) |> get(~p"/api/v1/offices")

      assert json_response(conn, 401)["error"]["code"] == "invalid_token"
    end

    test "an expired token says so, so a client knows to refresh", ctx do
      past = System.system_time(:second) - 60
      token = access_token(ctx, %{"exp" => past, "iat" => past - 300})
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 401)["error"]["code"] == "token_expired"
    end

    test "a valid token gets through", ctx do
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")

      assert json_response(conn, 200) == []
    end

    test "the 401 body is the unified error envelope", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/offices")

      assert %{"error" => %{"code" => _, "message" => message}} = json_response(conn, 401)
      assert is_binary(message)
    end
  end

  describe "role authorization" do
    test "a viewer may read", ctx do
      token = access_token(ctx, %{}, roles: ["viewer"])
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/visits")

      assert json_response(conn, 200)
    end

    test "a viewer may not write", ctx do
      token = access_token(ctx, %{}, roles: ["viewer"])
      patient = patient_fixture()

      conn =
        ctx.conn
        |> with_bearer(token)
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
      # Naming what was required and what was granted turns a 403 into
      # something an administrator can act on.
      assert "operator" in error["details"]["required"]
      assert error["details"]["granted"] == ["viewer"]
    end

    test "an operator may write", ctx do
      patient = patient_fixture()

      conn =
        ctx.conn
        |> with_bearer(access_token(ctx))
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert json_response(conn, 201)["patient_id"] == patient.id
    end

    test "a service account may write — this is the integration path", ctx do
      patient = patient_fixture()

      conn =
        ctx.conn
        |> with_bearer(service_token(ctx))
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert json_response(conn, 201)
    end

    test "an operator may not touch the catalog", ctx do
      conn =
        ctx.conn
        |> with_bearer(access_token(ctx))
        |> post(~p"/api/v1/capabilities", %{"capability" => %{"name" => "MRI"}})

      assert json_response(conn, 403)["error"]["details"]["required"] == ["admin"]
    end

    test "an admin may touch the catalog", ctx do
      token = access_token(ctx, %{}, roles: ["admin"])

      conn =
        ctx.conn
        |> with_bearer(token)
        |> post(~p"/api/v1/capabilities", %{"capability" => %{"name" => "MRI"}})

      assert json_response(conn, 201)["name"] == "MRI"
    end

    test "admin satisfies the write tier too", ctx do
      patient = patient_fixture()
      token = access_token(ctx, %{}, roles: ["admin"])

      conn =
        ctx.conn
        |> with_bearer(token)
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert json_response(conn, 201)
    end

    test "a token authenticated but carrying no recognised role reads nothing", ctx do
      token = access_token(ctx, %{}, roles: ["billing"])
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "webhook subscriptions are admin-only, including reads", ctx do
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/webhook_subscriptions")

      assert json_response(conn, 403)
    end
  end

  describe "audit attribution" do
    test "the visit event names the token's subject, not the request body", ctx do
      patient = patient_fixture()

      ctx.conn
      |> with_bearer(access_token(ctx))
      |> post(~p"/api/v1/visits", %{
        "visit" => %{"patient_id" => patient.id},
        # A caller trying to blame someone else. The token wins.
        "actor_type" => "user",
        "actor_id" => "somebody-else"
      })
      |> json_response(201)

      assert [event] = Audit.list_events(type: "visit.created")
      assert event.actor_type == "user"
      assert event.actor_id == "user-1"
    end

    test "a service token is attributed to its client id, not its uuid subject", ctx do
      patient = patient_fixture()

      ctx.conn
      |> with_bearer(service_token(ctx))
      |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})
      |> json_response(201)

      assert [event] = Audit.list_events(type: "visit.created")
      assert event.actor_type == "service"
      assert event.actor_id == "intake-bridge"
    end

    test "ending a visit is attributed to the token too", ctx do
      patient = patient_fixture()
      visit = Repo.insert!(Visit.changeset(%Visit{}, %{patient_id: patient.id}))

      ctx.conn
      |> with_bearer(service_token(ctx))
      |> post(~p"/api/v1/visits/#{visit.id}/end")
      |> json_response(200)

      assert [event] = Audit.list_events(type: "visit.ended")
      assert event.actor_id == "intake-bridge"
    end
  end
end
