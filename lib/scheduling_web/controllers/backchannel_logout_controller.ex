defmodule SchedulingWeb.BackchannelLogoutController do
  @moduledoc """
  Receives OpenID Connect Back-Channel Logout notifications.

      POST /auth/backchannel-logout
      Content-Type: application/x-www-form-urlencoded

      logout_token=<jwt>

  The identity provider calls this server-to-server when a session ends
  somewhere else — the operator signed out on another device, an administrator
  ended their session, the provider expired it. Without it, our signed session
  cookie keeps working for the rest of its 8h life regardless, because nothing
  about that cookie changes when the IdP's own session does.

  Kept out of `SchedulingWeb.AuthController` deliberately: that module is the
  browser handshake, driven by redirects and a session. This one is a machine
  caller with no session, no cookies and no CSRF token, and its own router
  pipeline to match.

  ## Responses

  Per Back-Channel Logout 1.0 §2.8, and shaped so a provider's retry logic does
  the right thing:

  | Case | Status | Meaning to the provider |
  |---|---|---|
  | Revoked | 200 | Done. |
  | Bad / forged / expired token | 400 | Permanent; do not retry. |
  | Provider unreachable for JWKS | 502 | Transient; retry is worthwhile. |
  | Auth not configured | 404 | This deployment has no sessions to end. |

  `Cache-Control: no-store` is required by the spec.
  """
  use SchedulingWeb, :controller

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Auth.SessionRevocation
  alias Scheduling.Auth.Tokens

  def create(conn, params) do
    if Auth.enabled?() do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> handle(params["logout_token"])
    else
      send_resp(conn, :not_found, "")
    end
  end

  defp handle(conn, token) when is_binary(token) and token != "" do
    case Tokens.validate_logout_token(token) do
      {:ok, %{sub: sub, sid: sid}} ->
        revoke(sid, sub)
        send_resp(conn, :ok, "")

      {:error, :provider_unavailable} ->
        # Ours, not theirs. 502 tells a well-behaved provider to retry rather
        # than drop the notification, which would leave the session live here.
        error(conn, :bad_gateway, "provider_unavailable")

      {:error, _reason} ->
        error(conn, :bad_request, "invalid_request")
    end
  end

  defp handle(conn, _token), do: error(conn, :bad_request, "invalid_request")

  # `sid` wins when present, and deliberately so.
  #
  # Back-Channel Logout 1.0 §2.4 lets a token carry `sub`, `sid`, or both. When
  # both are there the provider is naming *one session belonging to* that
  # subject — not every session they have. Revoking the subject as well would
  # sign an operator out at the nurses' station because they logged out on
  # their phone. Only a token with no `sid` means "everywhere".
  defp revoke(sid, sub) do
    if sid do
      SessionRevocation.revoke(:sid, sid)
      Logger.info("Back-channel logout: revoked session #{sid}")
    else
      SessionRevocation.revoke(:sub, sub)
      Logger.info("Back-channel logout: revoked every session for subject #{sub}")
    end
  end

  # The spec asks for a JSON body carrying an `error`. Deliberately terse: the
  # caller is a machine, and this endpoint is unauthenticated, so a detailed
  # reason is an oracle for anyone probing it. The specifics go to the log.
  defp error(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code}))
  end
end
