defmodule SchedulingWeb.BackchannelLogoutTest do
  @moduledoc """
  Back-channel logout: the endpoint, the token validation, and the revocation
  actually taking effect on a live session.

  The endpoint is public and unauthenticated — the signature on the logout
  token is the only thing standing between an attacker and the ability to sign
  arbitrary operators out. So the rejection cases matter as much as the happy
  path, and they are driven through the real `oidcc` validation path against
  the Bypass-hosted fake provider rather than a stub.

  `async: false` — see `Scheduling.OidcProvider`.
  """
  use SchedulingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Scheduling.OidcProvider

  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.SessionRevocation
  alias SchedulingWeb.Plugs.BrowserAuth

  setup :setup_oidc_provider

  # Mirrors the helper in browser_auth_test.exs: seeds a signed-in session
  # without driving the handshake, which is covered there.
  defp sign_in(conn, overrides \\ %{}) do
    identity =
      %{
        "sub" => "user-1",
        "email" => "acasey@example.org",
        "sid" => "session-1",
        "name" => "A. Casey",
        "astrum_roles" => ["operator"]
      }
      |> Map.merge(overrides)
      |> Identity.from_claims("scheduling")

    identity = %{identity | expires_at: System.system_time(:second) + 3600}

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(BrowserAuth.identity_key(), Identity.to_session(identity))
  end

  defp post_logout(conn, token) do
    post(conn, ~p"/auth/backchannel-logout", %{"logout_token" => token})
  end

  describe "ending a session" do
    test "a valid logout token turns a live session into a redirect", ctx do
      # The session works before the notification arrives...
      assert {:ok, _live, _html} = ctx.conn |> sign_in() |> live(~p"/board")

      assert ctx.conn |> post_logout(logout_token(ctx)) |> response(200)

      # ...and is gone after it, exactly like an expired one.
      assert {:error, {:redirect, %{to: "/auth/login"}}} =
               ctx.conn |> sign_in() |> live(~p"/board")
    end

    test "responds no-store, as the spec requires", ctx do
      conn = post_logout(ctx.conn, logout_token(ctx))

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a token naming both sub and sid ends only that session", ctx do
      # The common shape. The provider is naming one session belonging to this
      # subject, not all of them — so the operator's other device stays signed
      # in. Getting this wrong would sign someone out at the nurses' station
      # because they logged out on their phone.
      assert ctx.conn |> post_logout(logout_token(ctx)) |> response(200)

      assert {:ok, _live, _html} =
               ctx.conn |> sign_in(%{"sid" => "session-2"}) |> live(~p"/board")
    end

    test "a sub-only token signs that person out everywhere", ctx do
      token = logout_token(ctx, %{"sid" => :drop, "sub" => "user-1"})
      assert ctx.conn |> post_logout(token) |> response(200)

      # A different session for the same subject must also fall.
      assert {:error, {:redirect, %{to: "/auth/login"}}} =
               ctx.conn |> sign_in(%{"sid" => "session-99"}) |> live(~p"/board")
    end

    test "an unrelated operator is unaffected", ctx do
      assert ctx.conn |> post_logout(logout_token(ctx)) |> response(200)

      assert {:ok, _live, _html} =
               ctx.conn
               |> sign_in(%{"sub" => "user-2", "sid" => "session-2"})
               |> live(~p"/board")
    end

    test "redelivery of the same notification is not an error", ctx do
      token = logout_token(ctx)

      assert ctx.conn |> post_logout(token) |> response(200)
      assert ctx.conn |> post_logout(token) |> response(200)
    end
  end

  describe "rejecting tokens" do
    test "a token signed by a key the provider does not publish", ctx do
      forged = logout_token(ctx, %{}, jwk: JOSE.JWK.generate_key({:rsa, 2048}))

      assert ctx.conn |> post_logout(forged) |> json_response(400)
      refute revoked?("session-1")
    end

    test "a token with no events claim — i.e. a replayed ID token", ctx do
      assert ctx.conn
             |> post_logout(logout_token(ctx, %{"events" => :drop}))
             |> json_response(400)

      refute revoked?("session-1")
    end

    test "a token whose events claim names a different event", ctx do
      token = logout_token(ctx, %{"events" => %{"http://example.com/event/other" => %{}}})

      assert ctx.conn |> post_logout(token) |> json_response(400)
      refute revoked?("session-1")
    end

    test "a token carrying a nonce, which belongs only on an ID token", ctx do
      assert ctx.conn |> post_logout(logout_token(ctx, %{"nonce" => "n-1"})) |> json_response(400)
      refute revoked?("session-1")
    end

    test "a token naming neither sub nor sid", ctx do
      token = logout_token(ctx, %{"sub" => :drop, "sid" => :drop})

      assert ctx.conn |> post_logout(token) |> json_response(400)
    end

    test "a sid-only token — legal per the spec, but oidcc requires sub", ctx do
      # Back-Channel Logout 1.0 §2.4 allows sid instead of sub, but
      # oidcc_token:verify_missing_required_claims/1 requires sub on every JWT,
      # so it never reaches our checks. Pinned deliberately: if a provider
      # switches to sid-only tokens, logout silently stops working and this
      # test is the breadcrumb. See Scheduling.Auth.Tokens.validate_logout_token/1.
      token = logout_token(ctx, %{"sub" => :drop, "sid" => "session-1"})

      assert ctx.conn |> post_logout(token) |> json_response(400)
      refute revoked?("session-1")
    end

    test "an expired token", ctx do
      past = System.system_time(:second) - 60
      token = logout_token(ctx, %{"exp" => past, "iat" => past - 60})

      assert ctx.conn |> post_logout(token) |> json_response(400)
      refute revoked?("session-1")
    end

    test "a token from a different issuer", ctx do
      token = logout_token(ctx, %{"iss" => "https://elsewhere.example"})

      assert ctx.conn |> post_logout(token) |> json_response(400)
      refute revoked?("session-1")
    end

    test "a missing logout_token parameter", %{conn: conn} do
      assert conn |> post(~p"/auth/backchannel-logout", %{}) |> json_response(400)
    end

    test "garbage instead of a JWT", %{conn: conn} do
      assert conn |> post_logout("not-a-jwt") |> json_response(400)
    end

    test "the error body names no specifics — the endpoint is an open oracle", ctx do
      body = ctx.conn |> post_logout(logout_token(ctx, %{"nonce" => "n"})) |> json_response(400)

      assert body == %{"error" => "invalid_request"}
    end
  end

  describe "sweep/0" do
    test "removes only rows whose session would already have lapsed" do
      SessionRevocation.revoke(:sid, "live-session")
      SessionRevocation.revoke(:sid, "stale-session")
      expire("stale-session")

      assert SessionRevocation.sweep() == 1
      assert revoked?("live-session")
      refute revoked?("stale-session")
    end

    test "is a no-op when nothing has expired" do
      SessionRevocation.revoke(:sid, "live-session")

      assert SessionRevocation.sweep() == 0
      assert revoked?("live-session")
    end
  end

  defp revoked?(sid) do
    SessionRevocation.revoked?(%Identity{subject: "no-such-subject", sid: sid})
  end

  # Backdates a revocation past its expiry so the sweep will collect it.
  defp expire(sid) do
    import Ecto.Query

    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

    Scheduling.Repo.update_all(
      from(r in "revoked_sessions", where: r.value == ^sid),
      set: [expires_at: past]
    )
  end
end
