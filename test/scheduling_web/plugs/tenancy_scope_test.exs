defmodule SchedulingWeb.Plugs.TenancyScopeTest do
  @moduledoc """
  One deployment serves one organisation.

  The identity provider is multi-tenant; this app is not. A token from another
  organisation must be refused on **both** surfaces even when its roles would
  otherwise permit the call — otherwise a valid operator at one clinic could
  read another clinic's board with a perfectly genuine token.

  The check is off unless `expected_tenancy_id` is configured, so one group here
  pins that down: it is the state every other test in the suite runs in, and a
  regression that turned it on by default would break them all in a way that is
  easier to misread than to diagnose.

  `async: false` — see `Scheduling.OidcProvider`.
  """
  use SchedulingWeb.ConnCase, async: false

  import Scheduling.OidcProvider

  alias Scheduling.Auth
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo
  alias SchedulingWeb.Plugs.BrowserAuth

  # The org the fake provider's astrum-shaped tokens carry by default.
  @token_org "org-1"

  setup :setup_oidc_provider

  defp expect_tenant(org_id), do: put_auth_option(:expected_tenancy_id, org_id)

  describe "API — organisation matches" do
    setup do
      expect_tenant(@token_org)
      :ok
    end

    test "a token from this organisation is let through", ctx do
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")

      assert json_response(conn, 200) == []
    end

    test "a service token from this organisation is let through", ctx do
      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Jane Doe"}))

      conn =
        ctx.conn
        |> with_bearer(service_token(ctx))
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert json_response(conn, 201)
    end
  end

  describe "API — organisation does not match" do
    setup do
      expect_tenant("org-we-do-not-serve")
      :ok
    end

    test "a token from another organisation is refused", ctx do
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "forbidden"
      assert error["message"] =~ "organisation"
    end

    test "the refusal names the token's own org but never the expected one", ctx do
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")

      body = json_response(conn, 403)
      assert body["error"]["details"]["token_org_id"] == @token_org
      # Echoing what this deployment expects would hand any valid token the
      # tenant identity of every deployment it can reach.
      refute inspect(body) =~ "org-we-do-not-serve"
    end

    test "an admin token is refused too — roles do not override tenancy", ctx do
      token = access_token(ctx, %{}, roles: ["admin"])
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "a write is refused before it reaches the controller", ctx do
      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Jane Doe"}))

      conn =
        ctx.conn
        |> with_bearer(access_token(ctx))
        |> post(~p"/api/v1/visits", %{"visit" => %{"patient_id" => patient.id}})

      assert json_response(conn, 403)
      assert Scheduling.Visits.list_visits() == []
    end

    test "a token carrying no org claim at all is refused", ctx do
      # Either a claim-mapping mistake or a token from somewhere with no
      # tenancy. Neither is something to wave through.
      token = access_token(ctx, %{"astrum_org_id" => nil})
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "tenancy is checked before roles, so an unroled outsider gets one answer", ctx do
      token = access_token(ctx, %{}, roles: [])
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      body = json_response(conn, 403)
      assert body["error"]["details"]["token_org_id"] == @token_org
      refute body["error"]["details"]["required"]
    end

    test "an invalid token is still 401, not 403 — signature comes first", ctx do
      forged = access_token(ctx, %{}, jwk: JOSE.JWK.generate_key({:rsa, 2048}))
      conn = ctx.conn |> with_bearer(forged) |> get(~p"/api/v1/offices")

      assert json_response(conn, 401)["error"]["code"] == "invalid_token"
    end
  end

  describe "API — no organisation configured" do
    test "any organisation is accepted, which is how the rest of the suite runs", ctx do
      refute Auth.expected_tenancy_id()

      token = access_token(ctx, %{"astrum_org_id" => "some-other-org"})
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 200) == []
    end

    test "a token with no org claim is accepted too", ctx do
      token = access_token(ctx, %{"astrum_org_id" => nil})
      conn = ctx.conn |> with_bearer(token) |> get(~p"/api/v1/offices")

      assert json_response(conn, 200) == []
    end
  end

  describe "the tenancy claim is configurable" do
    # ac-core nests organization -> practice -> location and scopes /v1 reads
    # by practice, but advertises no claim named for a practice. So the claim
    # to check is configuration: point it elsewhere and the boundary moves
    # without a code change. This is what makes the unknown survivable.
    test "pointing it at another claim moves the boundary", ctx do
      put_auth_option(:tenancy_claim, "astrum_tenant")
      expect_tenant("northside")

      # The astrum-shaped fixture carries astrum_tenant: "northside".
      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")
      assert json_response(conn, 200) == []

      # ...and a token whose astrum_tenant differs is refused, even though its
      # astrum_org_id still matches what the default claim would have checked.
      other = access_token(ctx, %{"astrum_tenant" => "southside"})
      conn = build_conn() |> with_bearer(other) |> get(~p"/api/v1/offices")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "defaults to astrum_org_id, the only claim ac-core is confirmed to send" do
      assert Auth.tenancy_claim() == "astrum_org_id"
    end

    test "a claim the provider does not send refuses everyone", ctx do
      # The failure mode worth knowing about: a wrong claim name does not fail
      # open, it locks the whole deployment out.
      put_auth_option(:tenancy_claim, "astrum_practice_id")
      expect_tenant("practice-1")

      conn = ctx.conn |> with_bearer(access_token(ctx)) |> get(~p"/api/v1/offices")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  describe "Auth.tenancy_permitted?/1" do
    test "is the single source of truth both surfaces call" do
      refute Auth.expected_tenancy_id()
      assert Auth.tenancy_permitted?("anything")
      assert Auth.tenancy_permitted?(nil)

      expect_tenant("org-1")
      assert Auth.tenancy_permitted?("org-1")
      refute Auth.tenancy_permitted?("org-2")
      refute Auth.tenancy_permitted?(nil)
    end
  end

  # --- Browser sign-in -------------------------------------------------------
  #
  # Drives the real authorization-code flow: start at /auth/start to get a state
  # and nonce into the session, stub the provider's token endpoint to return an
  # ID token bound to that nonce, then follow the redirect back to
  # /auth/callback. This is the only place the code exchange runs end-to-end, so
  # it covers the happy path as well as the tenancy refusal.

  defp complete_login(ctx, claim_overrides \\ %{}) do
    conn = get(ctx.conn, ~p"/auth/start")
    state = Plug.Conn.get_session(conn, :oidc_state)
    nonce = Plug.Conn.get_session(conn, :oidc_nonce)

    stub_token_endpoint(ctx, nonce, claim_overrides)

    conn
    |> recycle()
    |> get(~p"/auth/callback?code=the-code&state=#{state}")
  end

  defp stub_token_endpoint(ctx, nonce, claim_overrides) do
    id_token = access_token(ctx, Map.put(claim_overrides, "nonce", nonce))
    access = access_token(ctx, claim_overrides)

    Bypass.stub(ctx.bypass, "POST", token_endpoint_path(), fn conn ->
      body =
        Jason.encode!(%{
          "access_token" => access,
          "id_token" => id_token,
          "token_type" => "Bearer",
          "expires_in" => 300,
          "scope" => "openid profile email roles"
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)
  end

  describe "browser sign-in" do
    test "an operator from this organisation is signed in", ctx do
      expect_tenant(@token_org)

      conn = complete_login(ctx)

      assert redirected_to(conn) == "/board"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed in"
    end

    test "an operator from another organisation is refused", ctx do
      expect_tenant("org-we-do-not-serve")

      conn = complete_login(ctx)

      assert redirected_to(conn) == "/auth/signed_out"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "different organisation"
    end

    test "the refusal leaves no session behind", ctx do
      expect_tenant("org-we-do-not-serve")

      conn = complete_login(ctx)

      assert Plug.Conn.get_session(conn, BrowserAuth.identity_key()) == nil
    end

    test "tenancy is checked before roles here too", ctx do
      expect_tenant("org-we-do-not-serve")

      # No recognised role either. The organisation message is the useful one:
      # granting this person a role would not get them in.
      conn = complete_login(ctx, %{"astrum_roles" => []})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "different organisation"
    end

    test "with no organisation configured, sign-in is unaffected", ctx do
      refute Auth.expected_tenancy_id()

      conn = complete_login(ctx, %{"astrum_org_id" => "some-other-org"})

      assert redirected_to(conn) == "/board"
    end
  end
end
