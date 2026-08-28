defmodule SchedulingWeb.ApiSpec do
  @moduledoc """
  The top-level OpenAPI document for the Scheduling API.

  Served as JSON at `/api/openapi.json`. Swagger UI lives at `/api/swagger`.
  Paths are derived from the router so they stay in sync with reality —
  each `:api`-pipelined route whose controller declares `OpenApiSpex.ControllerSpecs`
  operations gets included automatically.

  Security is declared once, at the document level, so it applies to every
  operation rather than needing a `security:` line per controller action.
  `/api/health` and the spec endpoints stay unauthenticated (see `security/0`),
  which is deliberate: an orchestrator's liveness probe must not need a token,
  and clients read the spec before they have one.
  """
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server
  alias SchedulingWeb.Endpoint
  alias SchedulingWeb.Router

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Scheduling API",
        version: Application.spec(:scheduling, :vsn) |> to_string(),
        description: """
        Operational HTTP API for the Scheduling app — patient flow (visits,
        queue entries, handoffs), the catalog that drives routing
        (capabilities, diagnoses, offices), and two append-only audit logs
        (`routing_decisions`, `visit_events`).

        ## Authentication

        Every `/api/v1` endpoint requires an OAuth 2.0 bearer token issued by
        the deployment's OpenID Connect provider. Integrations use the
        client-credentials grant:

            curl -s -X POST "$ISSUER/protocol/openid-connect/token" \\
              -d grant_type=client_credentials \\
              -d client_id=intake-bridge \\
              -d client_secret=...

        Then send `Authorization: Bearer <access_token>`.

        `GET /api/health`, `GET /api/openapi.json` and `GET /api/swagger` are
        unauthenticated — probes and clients reach them before they hold a
        token.

        ## Roles

        The token's roles decide what it may do. Roles are read from
        `realm_access.roles` and `resource_access.<client_id>.roles`.

        | Role       | May                                                        |
        |------------|------------------------------------------------------------|
        | `viewer`   | `GET` anything except webhook subscriptions                |
        | `operator` | the above, plus patient-flow writes                        |
        | `service`  | same as `operator` — the role for machine integrations     |
        | `admin`    | everything, including catalog CRUD and webhook subscriptions |

        ## Actor attribution

        Mutating endpoints record an actor on the resulting `visit_event`.
        This is taken from the token — `sub` for a user, the client id for a
        service account — and any `actor_type` / `actor_id` in the request
        body is ignored.

        ## Errors

        Every error shares one envelope:

            {"error": {"code": "...", "message": "...", "details": {...}}}

        `details` is present only when there is structured detail to give.
        Auth-specific codes: `unauthorized` (no token), `invalid_token`,
        `token_expired`, `forbidden` (401/401/401/403), and
        `provider_unavailable` (503) when the identity provider cannot be
        reached to verify a token.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description:
              "OAuth 2.0 access token from the deployment's OIDC provider. " <>
                "Obtain one with the client-credentials grant for service-to-service calls."
          }
        }
      },
      security: security()
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  # Applied to every operation. An empty requirement is not offered as an
  # alternative here, so Swagger UI prompts for a token by default; the three
  # unauthenticated endpoints override this with `security: []` on their own
  # operations.
  defp security, do: [%{"bearerAuth" => []}]
end
