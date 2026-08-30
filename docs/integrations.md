# Integrations

How Scheduling talks to the world. Two surfaces today: the HTTP API we
**expose** for consumers, and the **intake-form** REST API we consume at
the compliance gate. A third surface (check-in / queueing app) is still
pending — see `integration-contracts.md` for the decision record.

## Topology

```
[ac-core] ──── OIDC ─────▶ [Scheduling]      identity for operators + integrators
   ▲                            │
   └──── GET /v1/patients ──────┤            patient + location registry (read-only)
         GET /v1/locations      │
                                │
       sign-in                  │
[Check-in app] ──POST /api/v1/visits──▶
[Check-in app] ──POST /api/v1/queue_entries (visit_id, compliance_ref)──▶
                                │
                                │  on POST /queue_entries/:id/accept:
                                │
                                ├─► [Intake-form system]  compliance gate
                                │     GET /compliance/status?reference=…
                                │     (opaque ref in, verdict out)
                                │
                                ├─► [matcher]             best-fit office
                                ├─► [routing_decisions]   audit row
                                └─► [Handoff]             office staff notified
```

ac-core wears two hats: the **identity provider** both surfaces authenticate
against (`auth.md`), and the **system of record** for patients and locations
that scheduling reads from (`Scheduling.Core.Client`). The check-in app arrow
is still pending — see "What's pending" below.

Two audit logs, both append-only:

- `routing_decisions` — matcher-specific rows (one per accept attempt).
- `visit_events` — lifecycle events (sign-in, completion, handoff
  acknowledgement, future cancel / no_show / disposition). See *Audit
  logs* below.

## What we expose: Scheduling HTTP API

- **OpenAPI spec:** `GET /api/openapi.json` *(unversioned)*
- **Swagger UI:** `GET /api/swagger` *(unversioned)*
- **Health probe:** `GET /api/health` (200 `{"status":"ok"}` / 503 `{"status":"degraded"}`) *(unversioned)*
- **Everything else:** lives under `/api/v1/…`

### Versioning policy

All resource endpoints live under a `/api/v1/` prefix. Discovery
(`openapi.json`, `swagger`) and the health probe stay unversioned —
clients hit them before they know which version to use, and they may
evolve on their own cadence.

Future major versions are sibling scopes (`/api/v2/…`), introduced as
needed; old versions are deprecated with a sunset header before removal.
There is no breaking change *within* a major version — additive changes
only (new fields, new endpoints, new optional query params).

### Authentication

Integrators authenticate with an OAuth 2.0 access token from the deployment's
OIDC realm:

```sh
TOKEN=$(curl -s -X POST "$OIDC_ISSUER/oauth/token" \
  -d grant_type=client_credentials \
  -d client_id=intake-bridge -d client_secret=... | jq -r .access_token)

curl -s "$SCHEDULING_URL/api/v1/board" -H "Authorization: Bearer $TOKEN"
```

Give each integrating system **its own client** with the `service` role, so
one can be revoked without affecting the others and the audit log names which
system acted. Full realm setup, the role table and the auth error codes are in
**`auth.md`**.

The API mirrors every operation the LiveView UI offers — 41 endpoints across
11 tag groups (`capabilities`, `diagnoses`, `patients`, `offices`, `visits`,
`queue`, `handoffs`, `routing_decisions`, `visit_events`, `board`, `health`).
Browse the live spec; this document does not re-derive it.

Conventions:

- Raw JSON bodies, no `data:` wrapper.
- Requests use a per-resource envelope: `{"capability": {…}}`, `{"office": {…}}`.
- **Every error shares one envelope** (`sc-2y8`):
  `{"error": {"code": "...", "message": "...", "details": {...}}}`.
  `details` is present only when there is structured detail to give.
  Validation failures are **422** `validation_failed` with the field errors
  under `details.fields`; not-found is **404** `not_found`.
- Action endpoints under their resource: `POST /queue_entries/:id/accept`,
  `POST /handoffs/:id/acknowledge`, `POST /visits/:id/end`.
- **Every `/api/v1` endpoint requires a bearer token** (`sc-6ea`). Get one
  with the client-credentials grant; see `auth.md`. `GET /api/health`,
  `/api/openapi.json` and `/api/swagger` stay unauthenticated.
- The actor recorded on each `visit_event` comes from the **token** —
  `sub` for a user, the client id for a service account. `actor_type` and
  `actor_id` in the request body are ignored.

## What we consume: Intake-form system

Scheduling integrates with the intake-form REST API
(`{INTAKE_API_URL}/openapi.json` describes it) to **gate office assignments
behind form-completion compliance**. The intake app owns form definitions and
captured responses; we never store form answers, only the verdict (compliant
/ missing).

### Configuration

| Env var                  | Default                              | Required           |
|--------------------------|--------------------------------------|--------------------|
| `INTAKE_API_URL`         | `http://localhost:3001/api/v1`       | No                 |
| `INTAKE_API_KEY`         | (nil)                                | Yes, to enable gate |
| `INTAKE_HTTP_TIMEOUT_MS` | `5000`                               | No                 |

When `INTAKE_API_KEY` is unset (the default), the compliance gate is **disabled**
— every accept proceeds as if compliance had passed. This keeps the local-dev
quickstart working without an intake dependency. Set the key in production to
turn the gate on.

The API key is an intake "Bearer ik_…" token; provision it from the intake
app's admin surface.

### Data model

Two things wire a scheduling row to the intake system:

- `patients.intake_patient_id` (`uuid`, unique nullable) — the patient's id in
  the intake-form system. **The correlation key.** Set this when a patient is
  created or updated via `POST/PATCH /api/v1/patients`.
- `queue_entries.compliance_ref` (`string`, nullable) — an **opaque** reference
  supplied by whoever created the entry (ultimately from the EMR). Intake
  resolves it to the forms this encounter requires. Scheduling never learns
  what those are.

  It is **write-only**: settable on `POST /api/v1/queue_entries`, but not
  returned on entry reads. The system that sets it already knows it, and no
  other consumer needs it, so it is surfaced only in the `compliance_failed`
  error details — where it is actionable. Deliberate minimal exposure rather
  than an oversight; making it readable later would be an additive change.

`diagnoses.required_form_types` still exists as catalog data but is **no longer
read at accept time**. It is a routing-template attribute, not something
scheduling evaluates against a patient.

### Behavior

`POST /api/v1/queue_entries/:id/accept`:

1. **Compliance gate** runs first, when all of: `INTAKE_API_KEY` is set, the
   entry carries a `compliance_ref`, and the patient has an
   `intake_patient_id`. Any of those missing → the gate is skipped.
2. `GET {INTAKE_API_URL}/compliance/status?reference=<ref>&patient_id=<uuid>`
3. Intake answers `{"compliant": true|false}`.
4. **Matcher** runs next (unchanged — best-fit office with free capacity).

Outcomes (all written to the `routing_decisions` audit log with a
human-readable rationale):

| Outcome                                | HTTP | Body                                                                       | Entry state |
|----------------------------------------|------|----------------------------------------------------------------------------|-------------|
| Assigned                               | 200  | `QueueEntry` (status=`assigned`)                                           | assigned    |
| Compliant → matcher had no eligible office | 409  | `error.code = "no_eligible_office"`                                        | waiting     |
| Intake says not compliant              | 422  | `error.code = "compliance_failed"`, `error.details.compliance_ref`         | waiting     |
| Intake unreachable or the reference unresolvable | 503 | `error.code = "compliance_unavailable"`, `error.details.reason`      | waiting     |

**Fail-closed**: an unreachable intake blocks new bookings, and so does a
reference intake cannot resolve — passing an unknown encounter through the gate
would defeat the point. Bookings resume automatically when intake recovers.

> **This endpoint does not exist yet.** `/compliance/status` is a request to
> the intake team, analogous to the `?patient_id=` filter they added for
> `sc-c9j`. Until it ships, leave `INTAKE_API_KEY` unset — or simply create
> entries without a `compliance_ref`, which skips the gate.

### The data boundary (why the gate looks like this)

**Scheduling carries PII but not health data.** See `data-boundary.md` for the
full statement; the short version is that clinical data belongs in the EMR, and
this system deliberately cannot describe *why* a patient is here.

That is why the gate sends an opaque reference rather than form-type names.
Strings like `stroke-consent`, tied to a named patient, are health data — and
they used to reach four surfaces:

- `queue_entries` metadata (board snapshot, list endpoints)
- `routing_decisions.rationale` (append-only, and read by `/decisions`)
- `visit_events` (lifecycle log)
- every outbound webhook subscription

Earlier revisions of this document warned operators not to put sensitive
`formType` values into `required_form_types` for exactly that reason. That was
a policy asking humans to compensate for a design flaw. The design is now the
control: scheduling never receives the form types, so it cannot leak them, and
`test/scheduling/phi_boundary_test.exs` asserts it at each egress path.

For the same reason `queue_entries` no longer has a `diagnosis_id`. A diagnosis
may be passed to `POST /api/v1/queue_entries` as a convenience — it is expanded
to that diagnosis's default capabilities and discarded — but the association is
never stored.

### Known limitations

- The compliance call is **synchronous** inside `accept`. Slow intake = slow
  accept. It is now a single request per accept rather than one per required
  form type, so this matters less than it did. If it still bites:
  1. Short-TTL cache on the per-`(intake_patient_id, compliance_ref)` verdict.
  2. Precompute at entry creation and revalidate on a TTL.
  3. Move the check off the accept path entirely: a background job marks
     entries pre-cleared and `accept` only books those.
- The gate is **skipped when an entry has no `compliance_ref`**, which is every
  entry until ac-checkin starts supplying one. Fail-open, matching the
  unconfigured-intake default.

## What's pending: Check-in / queueing app

`docs/integration-contracts.md` (sc-7hs) is the decision record. The check-in
app **is the queueing service** — the same external system patients sign
into when arriving for an appointment. It emits the sign-in event that creates
the visit.

Decision: **wait for the real OpenAPI spec, then generate a client. Don't
build speculative stubs.** Today, queue entries are created via
`POST /api/v1/queue_entries` (admin / manual / test flows).

**Status (2026-08-29).** The spec has arrived and is vendored at
`ac-checkin.json` ("Avenue D Pediatrics — Check-in API", 195 paths). It changes
the picture, and `sc-bd8` stays held for different reasons than before — see
`integration-contracts.md` for the full reconciliation. In short:

- **There is no webhook.** The assumed `patient.checked_in` push does not
  exist. The only push surface is an undocumented `POST /fhir/r4/Subscription`.
- **The pull endpoint cannot identify a patient.**
  `GET /v1/external/queue` returns `{id, status, queuePosition, checkInTime}` —
  enough for a position board, not enough to create a visit.
- **11 of 12 external write endpoints have no documented request body**, so a
  client cannot be generated for them.
- **Auth federates to ac-core**, using `checkin:*` scopes on a core-issued
  token — the same source `Scheduling.Auth.ServiceToken` already uses. That
  part is ready.
- **The direction may be reversed.** `/v1/external/scheduling/*` is built for a
  federated app to publish schedules and book appointments *into* check-in,
  then mark them arrived. Whether appointments belong to this system or that
  one is an open question.

When the request bodies and a patient-identifying arrival signal land, the work
is:

1. Generate a client from the spec, and reconcile
   `integration-contracts.md`'s working assumptions against it.
2. Add a webhook receiver under `/api/v1/webhooks/check-in/...`.
   **It must not sit behind the `:api_write` pipeline**: the check-in app
   signs its own payloads and is not an OIDC client of ours, so it needs its
   own pipeline doing signature verification.
   `Scheduling.Webhooks.verify_signature/5` is the reference for the scheme in
   the outbound direction.
3. Dedupe on the external event id — delivery is at-least-once. Overlaps
   `sc-ry7`.
4. Add a periodic reconcile pull for dropped deliveries. This is the same
   advice we already give our own consumers.
5. Resolve the patient through ac-core (`core_patient_id`) rather than
   upserting by `external_id`. ac-core is the registry; `external_id` stays as
   the check-in app's own correlation key.

### Patient identity

Several systems reference the same human. **ac-core is the source of truth** —
it is the platform's patient registry, and scheduling holds a projection of the
fields it needs, not an authority of its own.

| Field on `patients`    | Owned by         | Used by                          |
|------------------------|------------------|----------------------------------|
| `core_patient_id`      | **ac-core**      | The identity of record                        |
| `client_id` (uuid)     | scheduling       | Legacy inter-service reference — **deprecated** |
| `external_id` (string) | check-in/queueing | Map check-in app's patient id    |
| `intake_patient_id` (uuid) | intake-form  | Compliance gate correlation      |

> **In transition.** `client_id` was scheduling's canonical id and is still
> generated, still unique, still filterable — nothing has broken. But it is no
> longer the authority: it names a row in *this* database, whereas
> `core_patient_id` names the person in the registry every other system shares.
> New integrations should exchange `core_patient_id`. `client_id` will be
> retired in a separate change once existing consumers have moved.

Scheduling projects only `id`, `practiceId`, `firstName` and `lastName` from a
core patient record and drops `mrn`, `dateOfBirth`, `phone` and `email` at the
client boundary — PII it could hold and has no use for. See
`data-boundary.md` §"Reading from ac-core".

`GET /api/v1/patients?core_patient_id=<id>` joins the two.

### Sites

`locations` is a second projection, from `GET /v1/locations`. ac-core owns the
site list; scheduling caches name, address, timezone and active state so the
board keeps its labels when the registry is briefly unreachable.

**A location is a site; an office is a room.** An ac-core location has an
address and a timezone; a scheduling office has an intake capacity and a set of
capabilities. Several offices sit in one site, so `offices.location_id` is a
nullable belongs-to — not a one-to-one projection.

Sync upserts by `core_location_id` and **deactivates** what ac-core stops
returning rather than deleting it: an office may point at that site, and a
vanished location is more often a scope change than a decision to erase
history. A sync that fails partway leaves what it wrote and changes nothing
else — in particular a failed sync never deactivates anything, which would
otherwise switch off every site on the pages it never fetched.

Sync never touches offices. Adopting a site's timezone happens when an
operator links a room (`Scheduling.Locations.link_office/2`), and only when the
office is still on the default — slot generation reads `Office.timezone`, so
changing it behind someone would move a whole calendar by an hour with no
audit trail.

Each of the three id columns is uniquely indexed and exposed as a query
filter on the two list endpoints integrators reach for most:

  GET /api/v1/patients?intake_patient_id=<uuid>
  GET /api/v1/patients?external_id=<string>
  GET /api/v1/patients?client_id=<uuid>

  GET /api/v1/queue_entries?intake_patient_id=<uuid>&status=waiting
  GET /api/v1/queue_entries?external_id=<string>
  GET /api/v1/queue_entries?client_id=<uuid>
  GET /api/v1/queue_entries?patient_id=<int>

Patient-side filters compose AND with `?status=` on queue_entries.
Typical bridge-style use: "does this patient already have a waiting
entry?" answered with one round-trip (no list-and-walk).

### Visit

A `Visit` represents one encounter — a patient's actual visit to the
facility, spanning potentially multiple queue entries (initial service,
follow-up procedure within the same day, etc.). The check-in / queueing
service is responsible for creating the visit when the patient signs in;
subsequent queue entries (including those created by outbound disposition)
link back via `queue_entries.visit_id`.

A Visit's status starts `active` and moves to `ended` when the patient is
finally discharged. Visit lifecycle and disposition semantics are tracked
under `sc-7hu` (state machine extensions).

API surface:

  POST /api/v1/visits             # sign-in
  GET  /api/v1/visits             # list, most-recent first
  GET  /api/v1/visits/:id         # show (preloads patient + queue_entries)
  POST /api/v1/visits/:id/end     # discharge (idempotent)

## Audit logs

Two append-only tables. Together they form the visit timeline; consumers
can query each separately or union them client-side.

### routing_decisions (matcher-specific)

One row per matcher run during `POST /queue_entries/:id/accept`. Captures
the chosen office (or `nil` when no eligible office), the eligible
candidate set, the required capability set, and a human-readable
`rationale` string. **Read-only.** Used for "why did the matcher pick
this office for this patient?" queries.

  GET /api/v1/routing_decisions    # most-recent first; supports ?since=<iso8601>
  GET /api/v1/routing_decisions/:id

### visit_events (lifecycle log)

Sibling to `routing_decisions`. Polymorphic `payload jsonb` for
per-type extras; FK references to `visits`, `queue_entries`, `patients`,
`handoffs` (all `on_delete: nilify_all` so the audit survives row
deletion). Today's event types:

| `type`                  | Recorded when                                  |
|-------------------------|------------------------------------------------|
| `visit.created`         | `POST /api/v1/visits`                             |
| `visit.ended`           | `POST /api/v1/visits/:id/end`                     |
| `queue_entry.created`   | `POST /api/v1/queue_entries`                      |
| `queue_entry.completed` | `POST /api/v1/queue_entries/:id/complete`         |
| `handoff.acknowledged`  | `POST /api/v1/handoffs/:id/acknowledge`           |

The accept-time outcomes (`assigned`, `no_eligible_office`,
`compliance_failed`, `compliance_unavailable`) stay in `routing_decisions`
to preserve their structured columns.

Each event carries:

- `type` — the event type string
- FK references that apply (visit_id / queue_entry_id / patient_id / handoff_id)
- `actor_type` + `actor_id` — split per the design discussion. Once
  `sc-6ea` (OAuth) lands these become the bearer token's subject claim.
  Today callers pass them in the request body of the mutating call.
- `payload` (jsonb) — event-specific extras (e.g.
  `queue_entry.completed.payload = {assigned_office_id: 17}`)
- `occurred_at` — defaults to the operation's natural timestamp
  (`visit.started_at`, `visit.ended_at`, `handoff.acknowledged_at`)

API surface:

  GET /api/v1/visit_events            # most-recent first; query filters:
                                      #   visit_id, queue_entry_id, patient_id,
                                      #   handoff_id, type, actor_type, actor_id,
                                      #   since=<iso8601>
  GET /api/v1/visit_events/:id

`since=<iso8601>` enables cheap incremental polling: pass the most
recent `occurred_at` from the previous response and the next call
returns only deltas (filter is `occurred_at >= since`, inclusive).
`/api/v1/routing_decisions` supports the same query param with the
matcher's `inserted_at` as the cursor.

### Pagination

Both audit-log endpoints (`/api/v1/visit_events` and
`/api/v1/routing_decisions`) support cursor pagination:

  GET /api/v1/visit_events?limit=N&after=<id>

- `limit` defaults to **100**, max **500**. Invalid values fall back to default.
- `after` is the id of the last row from the previous page.
- The response body stays a raw JSON array (no envelope).
- When more rows exist the response carries an `X-Next-Cursor` response
  header; pass its value as `?after=<id>` to fetch the next page. The
  header is absent at the end of the listing.

Pagination walks by id desc. For strictly chronological order across
pages, combine `?since=` for the time window with batched id paging
inside it.

Other list endpoints (capabilities, diagnoses, patients, offices,
visits, queue, handoffs) currently return all rows; pagination on those
is tracked in a follow-up bead.

Events are written inside `Ecto.Multi.transaction/0` so the row commits
with the operation — no half-state where an action succeeds but the
event is missing.

Additional event types will land alongside `sc-7hu`
(`queue_entry.cancelled`, `queue_entry.no_show`,
`disposition.next_entry_created`, …).

## Outbound webhooks

Scheduling can push signed HTTPS POSTs to subscriber URLs whenever a
`VisitEvent` is recorded. Saves integrators from polling, mirrors the
pattern the check-in app will use.

### Subscribe

```
POST /api/v1/webhook_subscriptions
{
  "webhook_subscription": {
    "url": "https://your-app.example/hooks/scheduling",
    "event_types": ["visit.created", "queue_entry.completed"],
    "description": "monitoring sink"
  }
}
```

Response (201) — **the only time the `secret` is returned**:

```
{
  "id": 7,
  "url": "...",
  "event_types": [...],
  "active": true,
  "secret": "<32-byte base64 url-safe>"
}
```

Subsequent `GET` / `PATCH` / `DELETE` responses omit `secret`. Rotation
= issue a new subscription, retire the old one.

`event_types: []` (or omitted) subscribes to **all** events.

### Delivery shape

Each delivery is a POST with these headers:

  Content-Type: application/json
  X-Scheduling-Event-Type: visit.created
  X-Scheduling-Timestamp: <unix-seconds>
  X-Scheduling-Signature: t=<unix-seconds>,v1=<hex>

The body is the same JSON shape that `GET /api/v1/visit_events/:id`
returns.

### Verifying signatures

`v1` is the lowercase-hex HMAC-SHA-256 of `"<timestamp>.<raw body>"`,
keyed by the secret you captured at subscription time:

```
signature == hex(HMAC-SHA256(secret, "<timestamp>.<raw_body>"))
```

Use a constant-time string compare. Reject deliveries whose timestamp
is too far in the past (the standard Stripe-style guard against replay
— 5 minutes is a reasonable default).

`Scheduling.Webhooks.verify_signature/5` is the canonical helper for
Elixir receivers; for other languages, the spec above is everything you
need.

### Delivery semantics (today)

- Fire-and-forget via `Task.start`: a slow receiver never blocks
  scheduling.
- No retries; non-2xx responses are dropped. Tracked under `sc-6ub`
  (delivery log + retries + DLQ). Until then, design your receiver to
  be idempotent on delivery duplicates and expect occasional drops on
  failure.
- No delivery log. If you need durability today, poll
  `/api/v1/visit_events?since=<iso8601>` in a reconciliation loop as a
  fallback.
- A subscription test-fire endpoint is tracked under `sc-yl8`.

## Local-dev recipe

Exercise the compliance gate against a local intake on `localhost:3001`:

```sh
# 1. Get an API key from the intake app (Bearer ik_…).
# 2. Restart the scheduling container with intake credentials.
container stop scheduling-app && container rm scheduling-app
container run -d --name scheduling-app --network scheduling \
  -e DATABASE_URL=ecto://scheduling:scheduling@192.168.67.2:5432/scheduling_dev \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e PHX_HOST=localhost -e PHX_SERVER=true -e PORT=4000 \
  -e INTAKE_API_URL=http://192.168.66.1:3001/api/v1 \
  -e INTAKE_API_KEY=ik_… \
  -p 4000:4000 scheduling-rig:latest
```

(No `OIDC_*` variables here, so auth is off and the endpoints below need
no token — see `auth.md` §"Local development". A `:prod` release refuses to
boot this way unless `AUTH_DISABLED=true` is also set.)

A note on the host: inside an Apple `container` instance, `localhost` is the
container itself. Use the host gateway IP (`192.168.66.1` on the `default`
network) to reach services on the macOS host. If intake is in a sibling
container on the same network, point at its container hostname or IP instead.

```sh
# 3. Create a patient with the intake UUID.
curl -X POST http://localhost:4000/api/v1/patients \
  -H 'content-type: application/json' \
  -d '{"patient":{"name":"Jane Doe","intake_patient_id":"<real-uuid>"}}'

# 4. Create a queue entry carrying a compliance reference. Note there is no
#    diagnosis on the entry — pass diagnosis_id if you want its capabilities
#    expanded onto the entry, but it is not stored (see "The data boundary").
curl -X POST http://localhost:4000/api/v1/queue_entries \
  -H 'content-type: application/json' \
  -d '{"queue_entry":{"patient_id":1,"compliance_ref":"<ref-intake-knows>"}}'

# 5. Accept it.
#    Expect: 200 if intake reports compliant,
#            422 compliance_failed (details.compliance_ref) if not,
#            503 compliance_unavailable if intake is unreachable or the
#                reference cannot be resolved.
#    Omit compliance_ref in step 4 and the gate is skipped entirely.
```

Watch the matcher audit log at `GET /api/routing_decisions` — every
accept attempt appears there with a rationale. Watch the lifecycle log
at `GET /api/v1/visit_events?visit_id=<id>` for the full timeline of a
visit.

## Open integration work (beads)

Pending feature work that affects integration shape. Track via `bd show
<id>` in the scheduling workspace.

> Statuses below were reconciled by hand on 2026-08-28. The Dolt server was
> not serving the `scheduling` database at the time (escalation
> `hq-wisp-pd2y`), so the beads themselves could not be updated — treat `bd`
> as authoritative once it is back, and re-check anything marked done here.

**Auth & lifecycle**

| Bead     | Scope                                                                                                       |
|----------|-------------------------------------------------------------------------------------------------------------|
| ~~`sc-6ea`~~ | **Done.** OIDC auth: browser SSO + service-to-service bearer tokens, roles from token claims. `actor_type`/`actor_id` now come from the token. See `auth.md`. |
| `sc-7hu` | Queue-entry state machine extensions: `scheduled`, `cancelled`, `no_show`, `discharged_with_followup`. Adds new event types to `visit_events`. |
| `sc-kub` | Service-to-service trust model. **Unblocked** — `sc-6ea` landed.                                            |
| `sc-ry7` | Idempotency-key handling for sign-in / disposition / outbound. **Unblocked** — and overlaps the dedupe work in the check-in ingest below. |
| `sc-ais` | Replay job for queue entries stuck on `compliance_unavailable` / `no_eligible_office`.                      |
| `sc-nm5` | Patient-facing notifications (SMS / email) for follow-ups.                                                  |

**Integration surface gaps**

| Bead     | Scope                                                                                                       |
|----------|-------------------------------------------------------------------------------------------------------------|
| ~~`sc-qsr`~~ | **Done.** Outbound webhooks for visit / queue / handoff events — see "Outbound webhooks" above. Retries and a delivery log are still open. |
| `sc-s7u` | Cursor pagination on every list endpoint.                                                                   |
| ~~`sc-2y8`~~ | **Done.** Unified error envelope (`{"error": {"code", "message", "details"}}`).                          |
| `sc-c41` | Rate limiting per token / per service. **Unblocked** — `sc-6ea` landed, so there is now a token to key on. |
| `sc-r5n` | External real-time subscription endpoint (SSE / WebSocket). **Unblocked** — `sc-6ea` landed.                |
| `sc-ckz` | Wait-time / queue-position read API for the queueing-service patient UI.                                    |
| `sc-jma` | Document the recommended generated-client / SDK toolchain.                                                  |
| `sc-j2s` | Cross-resource query / GraphQL story (deferred).                                                            |
