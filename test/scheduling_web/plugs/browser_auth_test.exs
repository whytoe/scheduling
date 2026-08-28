defmodule SchedulingWeb.Plugs.BrowserAuthTest do
  @moduledoc """
  Browser SSO: route guards, session handling, and the authorization-code
  handshake up to the point it leaves for the IdP.

  The code exchange itself is not driven here — that needs the IdP to mint a
  code, which the Bypass fake does not do. What *is* covered is everything an
  attacker touches: the state check, the absence of a flow, the open-redirect
  guard on `return_to`, and session expiry.

  `async: false` — see `Scheduling.OidcProvider`.
  """
  use SchedulingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Scheduling.OidcProvider

  alias Scheduling.Auth.Identity
  alias SchedulingWeb.Plugs.BrowserAuth

  setup :setup_oidc_provider

  # Seeds a signed-in session directly. The handshake that normally produces
  # it is exercised separately; this is about what happens afterwards.
  defp sign_in(conn, roles \\ ["operator"], overrides \\ %{}) do
    identity =
      %{
        "sub" => "user-1",
        "preferred_username" => "acasey",
        "name" => "A. Casey",
        "realm_access" => %{"roles" => roles}
      }
      |> Map.merge(overrides)
      |> Identity.from_claims("scheduling")

    identity = %{identity | expires_at: System.system_time(:second) + 3600}

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(BrowserAuth.identity_key(), Identity.to_session(identity))
  end

  describe "guarding the operator screens" do
    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/board")
    end

    test "every operator screen is guarded, not just the board", %{conn: conn} do
      for path <- ~w(/board /queue /decisions /visits /visit_events) do
        assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, path)
      end
    end

    test "a signed-in operator reaches the board", %{conn: conn} do
      {:ok, _live, html} = conn |> sign_in() |> live(~p"/board")

      assert html =~ "A. Casey"
    end

    test "an expired session is not a session", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(BrowserAuth.identity_key(), %{
          "sub" => "user-1",
          "roles" => ["operator"],
          "exp" => System.system_time(:second) - 1
        })

      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/board")
    end

    test "a session with no expiry recorded is treated as expired", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(BrowserAuth.identity_key(), %{
          "sub" => "user-1",
          "roles" => ["admin"]
        })

      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/board")
    end
  end

  describe "guarding the catalog screens" do
    test "an operator is refused", %{conn: conn} do
      conn = conn |> sign_in(["operator"]) |> get(~p"/offices")

      assert html_response(conn, 403) =~ "Not permitted"
    end

    test "the refusal names the role that would work", %{conn: conn} do
      conn = conn |> sign_in(["operator"]) |> get(~p"/offices")

      assert html_response(conn, 403) =~ "admin"
    end

    test "an admin gets in", %{conn: conn} do
      {:ok, _live, html} = conn |> sign_in(["admin"]) |> live(~p"/offices")

      assert html =~ "Offices"
    end

    test "the catalog tabs are hidden from an operator", %{conn: conn} do
      {:ok, _live, html} = conn |> sign_in(["operator"]) |> live(~p"/board")

      refute html =~ ~s(href="/offices")
      refute html =~ ~s(href="/capabilities")
    end

    test "the catalog tabs are shown to an admin", %{conn: conn} do
      {:ok, _live, html} = conn |> sign_in(["admin"]) |> live(~p"/board")

      assert html =~ "/offices"
    end
  end

  describe "starting the handshake" do
    test "redirects to the provider with state and PKCE", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      assert location = redirected_to(conn, 302)
      assert location =~ "/protocol/openid-connect/auth"
      assert location =~ "code_challenge="
      assert location =~ "code_challenge_method=S256"
      assert location =~ "state="
      assert location =~ "response_type=code"
    end

    test "remembers a local return path", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?return_to=/queue")

      assert Plug.Conn.get_session(conn, :auth_return_to) == "/queue"
    end

    test "refuses an absolute return_to — that would be an open redirect", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?return_to=https://evil.example/steal")

      assert Plug.Conn.get_session(conn, :auth_return_to) == nil
    end

    test "refuses a protocol-relative return_to", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?return_to=//evil.example")

      assert Plug.Conn.get_session(conn, :auth_return_to) == nil
    end

    test "refuses a backslash-smuggled return_to", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?return_to=/\\evil.example")

      assert Plug.Conn.get_session(conn, :auth_return_to) == nil
    end
  end

  describe "completing the handshake" do
    test "a callback with no login in progress is refused", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/auth/callback?code=abc&state=whatever")

      assert redirected_to(conn) == "/auth/signed_out"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be completed"
    end

    test "a callback whose state does not match is refused", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{oidc_state: "the-real-state"})
        |> get(~p"/auth/callback?code=abc&state=attacker-supplied")

      assert redirected_to(conn) == "/auth/signed_out"
    end

    test "the flow state is consumed, so a captured code cannot be replayed", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          oidc_state: "s",
          oidc_nonce: "n",
          oidc_pkce_verifier: "v"
        })
        |> get(~p"/auth/callback?code=abc&state=attacker-supplied")

      assert Plug.Conn.get_session(conn, :oidc_state) == nil
      assert Plug.Conn.get_session(conn, :oidc_pkce_verifier) == nil
    end

    test "a provider-side error lands on the signed-out page, not a stack trace", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/auth/callback?error=access_denied&error_description=User+said+no")

      assert redirected_to(conn) == "/auth/signed_out"
    end
  end

  describe "logout" do
    test "clears the session and hands off to the provider", %{conn: conn} do
      conn = conn |> sign_in() |> get(~p"/auth/logout")

      assert Plug.Conn.get_session(conn, BrowserAuth.identity_key()) == nil

      location = redirected_to(conn, 302)
      assert location =~ "/protocol/openid-connect/logout"
      assert location =~ "post_logout_redirect_uri="
    end

    test "the signed-out page is reachable without a session", %{conn: conn} do
      assert html_response(get(conn, ~p"/auth/signed_out"), 200) =~ "Sign in"
    end
  end
end
