# Deployment

`scheduling` is a Phoenix 1.8 LiveView app (Elixir 1.18 / OTP 27) backed by
PostgreSQL via Ecto. It ships as a self-contained OTP release inside a Docker
image. Anywhere that can run a container and reach a Postgres database can run
this app.

This document covers:

1. Local-first quickstart with `docker compose`
2. Image runtime contract
3. Environment variables
4. PostgreSQL requirements
5. Portable platform notes (Fly.io, Render, Cloud Run, ECS, …)

---

## 1. Local quickstart

Prerequisites: Docker Desktop (or compatible) with `docker compose`.

```bash
# One-time: generate a Phoenix secret key base
export SECRET_KEY_BASE=$(openssl rand -base64 48)

# Build the image and boot Postgres + the app
docker compose up --build
```

The first build takes a couple of minutes (deps + asset toolchain). On boot
the app runs pending Ecto migrations, then starts the Phoenix endpoint.

Open <http://localhost:4000>. Stop with `Ctrl-C`. Wipe DB state with
`docker compose down -v`.

To run only Postgres locally and develop against it with `mix phx.server`:

```bash
docker compose up -d db
# in another terminal
mix setup        # ecto.create + migrate + assets
mix phx.server
```

---

## 2. Runtime contract

| Property            | Value                                                            |
|---------------------|------------------------------------------------------------------|
| Image base          | `debian:bookworm-slim` (multi-stage from `hexpm/elixir`)         |
| Exposed port        | `4000` (override with `PORT`)                                    |
| Listen address      | `::` (IPv6 + IPv4 dual-stack)                                    |
| User                | non-root (`phoenix`, uid 1001)                                   |
| Health check        | `GET /api/health` → `200 {"status":"ok"}` (`503 {"status":"degraded"}` if the DB is unreachable) |
| Startup command     | `bin/scheduling eval 'Scheduling.Release.migrate()'` then `bin/scheduling start` |
| Stateless           | Yes — no local disk writes; scale horizontally                   |
| Graceful shutdown   | BEAM handles `SIGTERM`; platform should send it on stop          |

The health endpoint pings the database with `SELECT 1`, so platforms can use
it as both a liveness and a readiness probe.

---

## 3. Required environment variables

Provide these as **secrets** via the platform's native secret store. Do not
bake them into the image or commit them to the repo.

| Variable           | Purpose                                                              |
|--------------------|----------------------------------------------------------------------|
| `DATABASE_URL`     | PostgreSQL connection string, e.g. `ecto://user:pass@host:5432/scheduling_prod` |
| `SECRET_KEY_BASE`  | Phoenix session / cookie signing key (64+ bytes). Generate with `mix phx.gen.secret` or `openssl rand -base64 48`. |
| `PHX_HOST`         | Public hostname, e.g. `scheduling.example.com`. Used for URL generation. |
| `OIDC_ISSUER`      | OIDC issuer URL, e.g. `https://ac-core.45.59.71.47.nip.io`.          |
| `OIDC_CLIENT_ID`   | OAuth client id for this app, e.g. `scheduling`.                     |
| `OIDC_CLIENT_SECRET` | That client's secret.                                              |

**A `:prod` release refuses to boot without the three `OIDC_*` variables.**
Without them every screen and all 41 API endpoints are public, including
patient data. If that is genuinely what you want — the app sits on a private
network, or a reverse proxy authenticates in front of it — set
`AUTH_DISABLED=true`, which allows the boot and logs a warning. See
`docs/auth.md` for realm setup.

Optional:

| Variable            | Default      | Purpose                                                       |
|---------------------|--------------|---------------------------------------------------------------|
| `PORT`              | `4000`       | HTTP port the Phoenix endpoint listens on.                    |
| `PHX_SERVER`        | `true` (set by image) | Must be truthy for the release to start the HTTP server. |
| `POOL_SIZE`         | `10`         | Ecto connection pool size.                                    |
| `ECTO_IPV6`         | unset        | Set to `true`/`1` if the database host requires IPv6.         |
| `DNS_CLUSTER_QUERY` | unset        | Optional libcluster-style DNS-based clustering hostname.      |
| `OIDC_API_AUDIENCES` | unset    | Extra comma-separated `aud` values accepted on API access tokens. Needed when an integration's tokens carry an audience other than `OIDC_CLIENT_ID`. |
| `OIDC_SIGNING_ALGS` | `RS256`   | Comma-separated JWS algorithms accepted on access tokens.     |
| `OIDC_ROLE_CLAIMS`  | `astrum_roles,roles,realm_access.roles,resource_access.<client_id>.roles` | Dotted claim paths searched for roles; all present are unioned. |
| `OIDC_DISCOVERY_OVERRIDES` | `{"subject_types_supported":["public"]}` | JSON merged over the provider's discovery document. The default works around `ac-core` omitting a field OIDC Discovery marks REQUIRED; without it the app cannot boot. See `docs/auth.md`. |
| `OIDC_ORG_CLAIM` / `OIDC_ORG_ID_CLAIM` / `OIDC_TENANT_CLAIM` | `astrum_org` / `astrum_org_id` / `astrum_tenant` | Tenancy claims captured on the identity. |
| `SCHEDULING_TENANCY_ID` | unset     | Restricts the deployment to one tenant: a token whose tenancy id differs is refused. Unset = no check. |
| `CORE_API_URL`      | unset        | Base URL of the Avenue D Core API, e.g. `https://ac-core.example`. No default on purpose — a wrong host would send a bearer token somewhere unintended. |
| `CORE_CLIENT_ID` / `CORE_CLIENT_SECRET` | unset | OAuth client scheduling presents to ac-core. **A separate client from `OIDC_CLIENT_ID`** — that one identifies the web app to users; this one identifies scheduling-as-a-service and needs only read scopes. |
| `CORE_SCOPES`       | `core:patients:read,core:organizations:read` | Scopes on the core token. `core:patients:write` is deliberately absent — scheduling projects patient data, it does not author it. |
| `CORE_HTTP_TIMEOUT_MS` | `5000`    | Request timeout for core API calls.                           |
| `BOOKING_HORIZON_DAYS` | `60`      | How far ahead booking slots are generated.                    |
| `BOOKING_PRUNE_STALE_SLOTS` | `true` | Remove slots the availability rules no longer justify, after each horizon run. Only ever deletes an *unbooked, unblocked* slot; regeneration restores anything removed in error. Set `false` and a shortened rule leaves a room offering times it no longer works. |
| `OIDC_TENANCY_CLAIM` | `astrum_org_id` | Which claim carries the tenancy id. ac-core scopes data by *practice* but advertises no practice claim, so confirm against a real token before setting `SCHEDULING_TENANCY_ID` — a wrong claim name refuses everyone. See `docs/auth.md`. |
| `AUTH_SESSION_TTL_SECONDS` | `28800` (8h) | How long a browser session is trusted before re-auth.  |
| `AUTH_DISABLED`     | unset        | `true` allows a prod boot with no authentication. See above.  |

---

## 4. PostgreSQL requirements

- **Version:** PostgreSQL 14 or newer (any managed Postgres works: RDS, Cloud
  SQL, Neon, Supabase, Crunchy, …).
- **Connection:** the release expects a single connection URL via
  `DATABASE_URL`. SSL is currently disabled in `config/runtime.exs`; enable it
  there before deploying to a managed instance that requires it.
- **Migrations:** the image runs `Scheduling.Release.migrate()` at container
  startup. It is idempotent — repeated boots are safe. To roll back, exec into
  the container:
  ```bash
  bin/scheduling eval "Scheduling.Release.rollback(Scheduling.Repo, <version>)"
  ```

---

## 5. Portable platform notes

The image is generic. Pick whichever platform you prefer:

- **Fly.io.** `fly launch --image <your-image>`, set the secrets above with
  `fly secrets set ...`, attach a Fly Postgres or BYO managed Postgres. Fly
  sends `SIGTERM` on deploy/scale; BEAM handles it cleanly.
- **Render.** New Web Service from this image, add the env vars as secrets,
  link a Render Postgres add-on for `DATABASE_URL`.
- **Google Cloud Run.** Push the image to Artifact Registry, deploy with
  `--port=4000 --min-instances=1`, wire Cloud SQL via the unix socket or a
  Postgres URL. Set the env vars via `gcloud run services update --set-env-vars`
  (and `--set-secrets` for secrets in Secret Manager).
- **AWS ECS / Fargate.** Push to ECR, task definition uses the image, env from
  Secrets Manager / Parameter Store, RDS Postgres for `DATABASE_URL`.
- **DigitalOcean App Platform.** Connect this repo, App Platform builds from
  the Dockerfile, attach a managed Postgres database, set the secrets.
- **Kubernetes / Nomad.** Standard Deployment/Job — image, env from
  Secret/Vault, Service on port 4000, Postgres as a separate StatefulSet or
  external managed service.

The image has no platform-specific assumptions. If your platform can run a
container, give it a `DATABASE_URL`, and route HTTP to port 4000, the app
will boot, migrate, and serve.
