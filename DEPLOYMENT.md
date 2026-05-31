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

Optional:

| Variable            | Default      | Purpose                                                       |
|---------------------|--------------|---------------------------------------------------------------|
| `PORT`              | `4000`       | HTTP port the Phoenix endpoint listens on.                    |
| `PHX_SERVER`        | `true` (set by image) | Must be truthy for the release to start the HTTP server. |
| `POOL_SIZE`         | `10`         | Ecto connection pool size.                                    |
| `ECTO_IPV6`         | unset        | Set to `true`/`1` if the database host requires IPv6.         |
| `DNS_CLUSTER_QUERY` | unset        | Optional libcluster-style DNS-based clustering hostname.      |

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
