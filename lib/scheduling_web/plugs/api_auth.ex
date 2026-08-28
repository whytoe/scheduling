defmodule SchedulingWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token authentication and role authorization for `/api/v1`.

  Runs as two plugs so the router can say what a scope needs:

      plug SchedulingWeb.Plugs.ApiAuth                      # authenticate
      plug SchedulingWeb.Plugs.ApiAuth, :require_write      # + authorize

  Authentication puts a `Scheduling.Auth.Identity` on
  `conn.assigns.current_identity`; controllers read it through
  `SchedulingWeb.Api.Actor` to attribute audit events. When
  `Scheduling.Auth.enabled?/0` is false the plug assigns nothing and passes
  every request through, which is what keeps the unconfigured local-dev
  quickstart in `docs/integrations.md` working.

  ## Authorization

  | Requirement     | Satisfied by                          |
  |-----------------|---------------------------------------|
  | `:require_read` | any recognised role                   |
  | `:require_write`| `operator`, `service` (or `admin`)    |
  | `:require_admin`| `admin`                               |

  ## Responses

  Failures use the unified error envelope (`SchedulingWeb.ErrorEnvelope`), so
  a client parses an auth failure exactly like any other API error:

  | Case                              | Status | `error.code`           |
  |-----------------------------------|--------|------------------------|
  | No / malformed Authorization      | 401    | `unauthorized`         |
  | Bad signature, issuer, audience   | 401    | `invalid_token`        |
  | Expired token                     | 401    | `token_expired`        |
  | Valid token, insufficient role    | 403    | `forbidden`            |
  | IdP unreachable                   | 503    | `provider_unavailable` |

  401s carry a `WWW-Authenticate: Bearer` header per RFC 6750 so a generated
  client can tell "you need a token" from "your token is not good enough".
  """

  @behaviour Plug

  import Plug.Conn

  alias Scheduling.Auth
  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Tokens
  alias SchedulingWeb.ErrorEnvelope

  @write_roles ~w(operator service)

  @impl Plug
  def init(nil), do: :authenticate
  def init(requirement) when requirement in [:authenticate, :require_read], do: requirement
  def init(requirement) when requirement in [:require_write, :require_admin], do: requirement

  @impl Plug
  def call(conn, requirement) do
    if Auth.enabled?() do
      do_call(conn, requirement)
    else
      conn
    end
  end

  defp do_call(conn, :authenticate), do: authenticate(conn)

  defp do_call(conn, requirement) do
    conn = authenticate(conn)
    if conn.halted, do: conn, else: authorize(conn, requirement)
  end

  defp authenticate(conn) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, identity} <- Tokens.validate(token) do
      assign(conn, :current_identity, identity)
    else
      {:error, :missing} ->
        deny(conn, 401, "unauthorized", "A bearer token is required")

      {:error, :token_expired} ->
        deny(conn, 401, "token_expired", "The access token has expired")

      {:error, :provider_unavailable} ->
        deny(
          conn,
          503,
          "provider_unavailable",
          "The identity provider could not be reached to verify the token"
        )

      {:error, :invalid_token} ->
        deny(conn, 401, "invalid_token", "The access token is not valid")
    end
  end

  defp authorize(conn, requirement) do
    identity = conn.assigns.current_identity

    if permitted?(identity, requirement) do
      conn
    else
      deny(
        conn,
        403,
        "forbidden",
        "This token's roles do not permit that operation",
        %{required: required_roles(requirement), granted: identity.roles}
      )
    end
  end

  defp permitted?(identity, :require_read), do: Identity.can_read?(identity)
  defp permitted?(identity, :require_write), do: Identity.has_any_role?(identity, @write_roles)
  defp permitted?(identity, :require_admin), do: Identity.has_role?(identity, "admin")

  defp required_roles(:require_read), do: Identity.known_roles()
  defp required_roles(:require_write), do: @write_roles ++ ["admin"]
  defp required_roles(:require_admin), do: ["admin"]

  # RFC 6750 §2.1: exactly "Bearer <token>", case-insensitive on the scheme.
  # A second Authorization header is ambiguous, so refuse rather than pick one.
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] ->
            token = String.trim(token)

            if String.downcase(scheme) == "bearer" and token != "",
              do: {:ok, token},
              else: {:error, :missing}

          _ ->
            {:error, :missing}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp deny(conn, status, code, message, details \\ nil) do
    conn
    |> maybe_challenge(status, code, message)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(ErrorEnvelope.error_envelope(code, message, details)))
    |> halt()
  end

  defp maybe_challenge(conn, 401, code, message) do
    put_resp_header(
      conn,
      "www-authenticate",
      ~s(Bearer realm="scheduling", error="#{code}", error_description="#{message}")
    )
  end

  defp maybe_challenge(conn, _status, _code, _message), do: conn
end
