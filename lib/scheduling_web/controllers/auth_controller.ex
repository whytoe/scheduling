defmodule SchedulingWeb.AuthController do
  @moduledoc """
  Browser SSO — the OIDC authorization-code flow with PKCE.

      GET  /auth/login     -> redirect to the IdP
      GET  /auth/callback  <- the IdP redirects back with ?code&state
      POST /auth/logout    -> clear the session, then RP-initiated logout

  ## What is kept in the session

  Only the compact identity map from `Scheduling.Auth.Identity.to_session/1` —
  never the access, refresh or ID token. Two reasons: the session is a signed
  (not encrypted) cookie capped at 4KB, and a Keycloak token triple can
  exceed that on its own; and a cookie that never holds a token has no token
  to leak if it is stolen.

  The consequence is that there is no refresh token to refresh with. When the
  session's `exp` passes, `SchedulingWeb.Plugs.BrowserAuth` bounces the user
  back through `/auth/login` — which the IdP answers silently from its own SSO
  cookie if the Keycloak session is still alive. The user sees a redirect, not
  a login form.

  ## CSRF

  `state` is a random value stored in the session and compared on callback,
  per OAuth 2.0 §10.12. PKCE (`code_challenge`/`code_verifier`, RFC 7636)
  additionally binds the authorization code to this browser, so an intercepted
  code cannot be redeemed elsewhere. Both the state and the verifier are
  dropped from the session as soon as the callback consumes them, so a
  captured code can never be replayed against a second callback.
  """
  use SchedulingWeb, :controller

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Tokens
  alias SchedulingWeb.Plugs.BrowserAuth

  @state_key :oidc_state
  @nonce_key :oidc_nonce
  @verifier_key :oidc_pkce_verifier

  @doc """
  The sign-in page.

  A deliberate stop rather than an immediate bounce to the IdP. Redirecting
  straight out means an operator who lands here — session expired mid-shift,
  or a bookmark opened cold — is thrown to another origin before they have
  read anything, and a provider that is down or misconfigured produces a
  bare browser error on a hostname they do not recognise. A page that names
  where they are going, and goes only when they ask, fails visibly here
  instead.

  `?return_to=` (a local path) is remembered now, so `start/2` needs nothing
  from the query string and the value never round-trips through the rendered
  page. `BrowserAuth.require_authenticated/2` has usually stored it already.
  """
  def login(conn, params) do
    if Auth.enabled?() do
      conn
      |> BrowserAuth.put_return_to(params["return_to"])
      |> standalone()
      |> render(:login)
    else
      redirect(conn, to: ~p"/board")
    end
  end

  @doc """
  Hands off to the IdP: builds the authorization URL and redirects.

  Split from `login/2` so the page above can exist. Everything
  security-relevant to the flow — `state`, `nonce`, PKCE verifier — is minted
  here, at the moment of departure, rather than when the page was rendered:
  a login page left open in a tab overnight should still start a fresh flow.
  """
  def start(conn, _params) do
    if Auth.enabled?() do
      state = random_value()
      nonce = random_value()
      verifier = random_value()

      opts = %{
        redirect_uri: redirect_uri(conn),
        scopes: Auth.scopes(),
        state: state,
        nonce: nonce,
        pkce_verifier: verifier
      }

      case Oidcc.create_redirect_url(
             Auth.provider_name(),
             Auth.client_id(),
             Auth.client_secret(),
             opts
           ) do
        {:ok, url} ->
          conn
          |> put_session(@state_key, state)
          |> put_session(@nonce_key, nonce)
          |> put_session(@verifier_key, verifier)
          |> redirect(external: IO.iodata_to_binary(url))

        {:error, reason} ->
          Logger.error("Could not build the OIDC redirect URL: #{inspect(reason)}")
          unavailable(conn)
      end
    else
      redirect(conn, to: ~p"/board")
    end
  end

  @doc """
  Completes the login: verifies `state`, exchanges the code for tokens, and
  stores the resulting identity in the session.
  """
  def callback(conn, %{"error" => error} = params) do
    # The IdP declined — the user cancelled at the consent screen, or the
    # client is misconfigured. `error_description` is the IdP's, so log it and
    # show the generic page rather than reflecting it back into the response.
    Logger.warning("OIDC callback returned #{error}: #{inspect(params["error_description"])}")
    denied(conn)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, @state_key)
    nonce = get_session(conn, @nonce_key)
    verifier = get_session(conn, @verifier_key)

    conn = clear_flow_state(conn)

    cond do
      is_nil(expected_state) ->
        # No flow in progress: a stale bookmark, a replayed callback, or a
        # login started in a session that has since been cleared.
        Logger.warning("OIDC callback with no login in progress")
        denied(conn)

      not Plug.Crypto.secure_compare(state, expected_state) ->
        Logger.warning("OIDC callback state mismatch")
        denied(conn)

      true ->
        exchange(conn, code, nonce, verifier)
    end
  end

  def callback(conn, _params), do: denied(clear_flow_state(conn))

  @doc """
  The page a signed-out — or role-less — operator lands on. Public by
  necessity: requiring a scope here would be a redirect loop.
  """
  def signed_out(conn, _params) do
    conn
    |> standalone()
    |> render(:signed_out)
  end

  @doc """
  Logs out locally, then hands off to the IdP so the Keycloak session ends
  too — otherwise `/auth/login` would silently sign the user straight back in.
  """
  def logout(conn, _params) do
    conn = BrowserAuth.log_out(conn)

    case logout_url(conn) do
      {:ok, url} -> redirect(conn, external: url)
      :error -> redirect(conn, to: ~p"/")
    end
  end

  defp exchange(conn, code, nonce, verifier) do
    opts = %{
      redirect_uri: redirect_uri(conn),
      nonce: nonce,
      pkce_verifier: verifier
    }

    case Oidcc.retrieve_token(
           code,
           Auth.provider_name(),
           Auth.client_id(),
           Auth.client_secret(),
           opts
         ) do
      {:ok, token} ->
        sign_in(conn, Tokens.identity_from_login(token))

      {:error, reason} ->
        Logger.warning("OIDC code exchange failed: #{inspect(reason)}")
        denied(conn)
    end
  end

  defp sign_in(conn, %Identity{} = identity) do
    cond do
      # Tenancy before roles: someone from another tenant should be told they
      # are at the wrong deployment, not that their roles are wrong here.
      not Auth.tenancy_permitted?(identity.tenancy_id) ->
        Logger.warning(
          "Denied #{identity.subject}: tenant #{inspect(identity.tenancy_id)} is not the one this deployment serves"
        )

        conn
        |> put_flash(
          :error,
          gettext(
            "Your account belongs to a different organisation than this scheduling system serves."
          )
        )
        |> redirect(to: ~p"/auth/signed_out")

      # Authenticated against the realm but granted nothing here. Saying so
      # plainly beats an empty board that looks broken.
      not Identity.can_read?(identity) ->
        Logger.warning("Denied #{identity.subject}: no recognised role")

        conn
        |> put_flash(
          :error,
          gettext(
            "Your account has no Scheduling role assigned. Ask an administrator for access."
          )
        )
        |> redirect(to: ~p"/auth/signed_out")

      true ->
        Logger.info("Signed in #{identity.subject} with roles #{inspect(identity.roles)}")

        # Read before log_in — renewing the session drops the remembered path.
        return_to = BrowserAuth.take_return_to(conn)

        conn
        |> BrowserAuth.log_in(identity)
        |> put_flash(:info, gettext("Signed in as %{name}", name: Identity.label(identity)))
        |> redirect(to: return_to)
    end
  end

  defp denied(conn) do
    conn
    |> put_flash(:error, gettext("Sign-in could not be completed. Please try again."))
    |> redirect(to: ~p"/auth/signed_out")
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, gettext("The sign-in service is unavailable. Please try again shortly."))
    |> redirect(to: ~p"/auth/signed_out")
  end

  # No `id_token_hint` to offer — we deliberately don't keep the ID token.
  # RP-initiated logout allows `client_id` + `post_logout_redirect_uri`
  # instead (OIDC RP-Initiated Logout 1.0 §2; Keycloak 18+ accepts it).
  defp logout_url(conn) do
    case Oidcc.initiate_logout_url(:undefined, Auth.provider_name(), Auth.client_id(), %{
           post_logout_redirect_uri: url(conn, ~p"/auth/signed_out")
         }) do
      {:ok, url} ->
        {:ok, IO.iodata_to_binary(url)}

      {:error, reason} ->
        Logger.warning("Could not build the OIDC logout URL: #{inspect(reason)}")
        :error
    end
  end

  defp clear_flow_state(conn) do
    conn
    |> delete_session(@state_key)
    |> delete_session(@nonce_key)
    |> delete_session(@verifier_key)
  end

  # AuthHTML renders complete documents (see its moduledoc), so both the root
  # layout the :browser pipeline installed and the app layout must come off.
  defp standalone(conn) do
    conn
    |> put_root_layout(html: false)
    |> put_layout(false)
  end

  defp redirect_uri(conn), do: url(conn, ~p"/auth/callback")

  defp random_value, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
