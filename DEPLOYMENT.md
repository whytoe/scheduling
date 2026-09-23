# Deployment

`scheduling` is a Phoenix 1.8 LiveView app (Elixir 1.18.5 / OTP 27.3.4.17) backed by
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
| User                | non-root (`phoenix`, uid 1000 — matches platforms that impose `runAsUser: 1000`) |
| Health check        | `GET /api/health` → `200 {"status":"ok"}` (`503 {"status":"degraded"}` if the DB is unreachable) |
| Startup command     | `bin/scheduling eval 'Scheduling.Release.migrate()'` then `bin/scheduling start` |
| Stateless           | Yes — no local disk writes; scale horizontally                   |
| Graceful shutdown   | BEAM handles `SIGTERM`; platform should send it on stop          |

The health endpoint pings the database with `SELECT 1`, so platforms can use
it as both a liveness and a readiness probe.

### Toolchain

| | |
|---|---|
| Elixir | `1.18.5` |
| Erlang/OTP | `27.3.4.17` |
| Debian snapshot | `bookworm-20260918-slim` |

All three live as `ARG`s at the top of the `Dockerfile` and nowhere else. CI
reads them out of that file, so a bump moves the pull-request checks in the same
commit and a green check is evidence about the artifact that ships.

**They are not independently choosable.** hexpm publishes one image per
`(elixir, erlang, debian-snapshot)` triple, and only for combinations it
happened to build — so moving the OTP patch level can force the Elixir patch and
the Debian snapshot along with it. Check
[hub.docker.com/r/hexpm/elixir/tags](https://hub.docker.com/r/hexpm/elixir/tags)
before editing any of the three. `DEBIAN_VERSION` additionally has to exist as a
`debian:` tag, because the same `ARG` names the runner base.

**Name the patch, not the series.** `OTP_VERSION=27.3` reads like a pin and is
not one: the 27.3 series has 21 patch releases behind it. A four-component
version is a version somebody chose.

#### Why this one (evaluated 2026-09-20, `sc-c3g`)

OTP patch releases inside a series carry security fixes. Between `OTP-27.3` and
`OTP-27.3.4.17` there are **56 CVEs**, two of them critical, counted from
[erlang/otp's advisory database](https://github.com/erlang/otp/security/advisories).
The ones that are actually reachable from this release are the reason for the
bump rather than the headline count:

- **Reachable.** Everything in `ssl` / `public_key`, because every outbound call
  this app makes is HTTPS — ac-core for OIDC and the core API, intakeform for
  the compliance gate. That includes `CVE-2026-55953` (critical, (D)TLS-1.2
  server certificate verification bypass), `CVE-2026-42790` (hostname
  verification falling back to subject CN), `CVE-2026-42789` (a non-CA
  certificate accepted as an intermediate issuer) and `CVE-2026-32144` (OCSP
  designated-responder authorization bypass).
- **Reachable.** `httpc`, which is not an implementation detail here: `oidcc`
  declares `extra_applications: [:inets, :ssl]` and issues every OIDC request
  through `httpc:request/5`. So discovery, JWKS, the token exchange and
  introspection all run through it — and `CVE-2026-48856` is *"httpc leaks
  Authorization header to cross-origin redirect targets"*, on calls that carry
  this deployment's client credentials.
- **Not reachable.** `CVE-2025-32433`, the CVSS 10.0 unauthenticated SSH RCE, is
  in the `ssh` application's daemon. `ssh` is not in the release at all — check
  with `ls _build/prod/rel/scheduling/lib`. Worth stating plainly rather than
  quoting the 10.0 and letting it do the arguing.
- **Not reachable.** The `inets httpd` cluster — request smuggling,
  `mod_auth` bypasses, slowloris. `inets` ships because `oidcc` wants `httpc`,
  but nothing starts `httpd`; Phoenix serves through Bandit.

Elixir moved `1.18.4` → `1.18.5` because it had to: no `1.18.4` image exists for
any OTP newer than `27.3.4.16`. It is not a cost — `1.18.5` is a
[security-only release](https://github.com/elixir-lang/elixir/releases/tag/v1.18.5)
whose notes contain exactly one entry, `CVE-2026-75758`, which `1.18.4` carries
unfixed.

The Debian snapshot moved for the same reason, and picks up that snapshot's
package updates for both the builder and the runner.

### Dependency advisories

The reasoning above covers the runtime. The dependencies have the same problem
and had no answer at all until `sc-soe`: `mix deps.get` mentions advisories in
one line that scrolls past fifty package fetches, and nothing else looked.

The `audit` job in `.github/workflows/ci.yml` runs `mix hex.audit` on the
**weekly schedule**, not on pull requests, and can be started by hand with
`workflow_dispatch`. Not on pull requests because an advisory is published
against a dependency nobody here has touched: gating a pull request on it turns
somebody's unrelated diff red for a reason that diff cannot explain, which is
how a check like this ends up switched off. Same argument, same schedule, as
the loose toolchain pin.

Two things about `mix hex.audit` are worth knowing before trusting it:

- **It needs Hex 2.5.0 or newer.** Before that it reported *retired* packages
  only — on an older Hex it prints "No retired packages found" and exits 0 no
  matter how many advisories stand. The job asserts the version first, because
  the failure mode is a green check that examined nothing.
- **It reads `mix.lock`,** so `MIX_ENV` does not narrow it and test-only
  dependencies are audited too. That is intended: they run on CI machines and
  on laptops.

An advisory that genuinely does not apply is acknowledged rather than ignored
— list its id under `ignore_advisories` in the `:hex` block of `mix.exs`, with
a comment saying why it does not reach this application. Deleting the step is
not the alternative to that; it is the thing `ignore_advisories` exists to
prevent.

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

On an orchestrator this shows up as a container that exits at startup and is
restarted — `CrashLoopBackOff` on Kubernetes. **The diagnosis is in the
container log, and the log is on the previous attempt**, so reach for it
directly rather than reading the pod status:

```bash
kubectl logs <pod> --previous     # or: docker logs <container>
```

The refusal names each variable:

```
Authentication is not configured.

    OIDC_ISSUER         set
    OIDC_CLIENT_ID      set
    OIDC_CLIENT_SECRET  SET BUT EMPTY
```

- `MISSING` — nothing supplied the variable. Look at the manifest.
- `SET BUT EMPTY` — it arrived carrying nothing. The secret did not get
  delivered; look at the platform's secret store, not the manifest.
- Three `set` lines under *"Authentication is not configured"* means the guard
  is wrong, not your deployment. File it.

Note that the image runs migrations before starting the server
(`bin/scheduling eval ... && bin/scheduling start`), and `eval` evaluates
`config/runtime.exs` too — so a release configured this way fails at the
migrate step, before the server is ever reached.

Values are never printed. One of the three is a client secret.

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

### lmfarm: don't deploy during registry garbage collection

On the lmfarm deployment, do **not** trigger a build between **03:00 and ~03:15
UTC**. The registry's nightly garbage collection runs in that window, and a
build whose image is pushed while GC is computing what to keep can have its
manifest deleted moments after the build reports "succeeded" — leaving a build
marked green whose image cannot be pulled. Every rollout and redeploy then hits
`ErrImagePull` / `ImagePullBackOff`; production is unaffected because the prior
revision keeps serving.

Recovery: a plain `lmfarm services redeploy` does **not** help — it reuses the
deleted digest. Trigger a **fresh build** (push a new commit to `main`) so a new,
resolvable digest is pushed. Recorded as platform incident `cabd05f1`
(2026-09-23); the platform is separately fixing GC so it no longer runs
concurrently with image pushes.
