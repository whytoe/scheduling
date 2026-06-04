# Integrations

How Scheduling talks to the world. Two surfaces today: the HTTP API we
**expose** for consumers, and the **intake-form** REST API we consume at
the compliance gate. A third surface (check-in / queueing app) is still
pending — see `integration-contracts.md` for the decision record.

## Topology

```
       sign-in
[Queueing app] ───POST /api/v1/visits───▶ [Scheduling]
[Queueing app] ───POST /api/v1/queue_entries (with visit_id)──▶
                                            │
                                            │  on POST /queue_entries/:id/accept:
                                            │
                                            ├─► [Intake-form system]   compliance gate
                                            │      GET /responses        (per required form_type)
                                            │
                                            ├─► [matcher]              best-fit office
                                            ├─► [routing_decisions]    audit row
                                            └─► [Handoff]              office staff notified
```

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

The API mirrors every operation the LiveView UI offers — 41 endpoints across
11 tag groups (`capabilities`, `diagnoses`, `patients`, `offices`, `visits`,
`queue`, `handoffs`, `routing_decisions`, `visit_events`, `board`, `health`).
Browse the live spec; this document does not re-derive it.

Conventions:

- Raw JSON bodies, no `data:` wrapper.
- Requests use a per-resource envelope: `{"capability": {…}}`, `{"office": {…}}`.
- Validation errors → **422** with `{"errors": {field: [msgs]}}` (Ecto changeset
  traversal).
- Not found → **404** with `{"error":"not_found"}`.
- Action endpoints under their resource: `POST /queue_entries/:id/accept`,
  `POST /handoffs/:id/acknowledge`, `POST /visits/:id/end`.
- All mutating endpoints accept an optional `actor_type` + `actor_id` at
  the top level of the request body. These are recorded on the
  corresponding `visit_event`. Once `sc-6ea` (OAuth) lands, these come
  from the bearer token's subject claim and become required.

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

Two columns wire scheduling rows to intake rows:

- `patients.intake_patient_id` (`uuid`, unique nullable) — the patient's id in
  the intake-form system. **The correlation key** when looking up form
  responses. Set this when a patient is created or updated via
  `POST/PATCH /api/v1/patients`.
- `diagnoses.required_form_types` (`text[]`, default `[]`) — the intake
  `formType` strings that must be on file (status `completed` AND not
  `flagged`) before a patient with this diagnosis can be assigned to an
  office. Set via `POST/PATCH /api/v1/diagnoses`.

Forms-required lives on the **diagnosis**, not the capability, because
compliance is service-defined (what visit is the patient here for?), not
equipment-defined (which room equipment will be used?). This decision is
re-litigable; the join is small.

### Behavior

`POST /api/v1/queue_entries/:id/accept`:

1. **Compliance gate** runs first (when `INTAKE_API_KEY` is set).
2. For each form type in the entry's diagnosis's `required_form_types`:
   1. `GET {INTAKE_API_URL}/responses?form_type=<type>&status=completed&limit=200`
   2. Filter client-side for `patientId == patient.intake_patient_id`
   3. Require `flagged == false`
3. **Matcher** runs next (unchanged — best-fit office with free capacity).

Outcomes (all written to the `routing_decisions` audit log with a
human-readable rationale):

| Outcome                                | HTTP | Body                                                                       | Entry state |
|----------------------------------------|------|----------------------------------------------------------------------------|-------------|
| Assigned                               | 200  | `QueueEntry` (status=`assigned`)                                           | assigned    |
| All required forms satisfied → matcher had no eligible office | 409  | `{"error":"no_eligible_office"}`                                           | waiting     |
| At least one required form missing     | 422  | `{"error":"compliance_failed","missing_form_types":[…]}`                   | waiting     |
| Intake-form system unreachable         | 503  | `{"error":"compliance_unavailable","reason":"<inspect>"}`                  | waiting     |

**Fail-closed**: an unreachable intake system blocks new bookings. The audit
log records every blocked attempt so operations can see the failure
immediately. Bookings resume automatically when intake recovers.

When the diagnosis requires no forms (`required_form_types == []`) or the
patient has no `intake_patient_id`, the gate behaves as follows:

- No required types → **skip** the check, proceed to matcher.
- Required types AND no `intake_patient_id` → **block** with
  `compliance_failed`, listing every required type as missing. (You can't
  satisfy compliance for a patient we can't correlate.)

### Known limitations

- The intake `/responses` endpoint does **not** accept a `patient_id` query
  parameter. We pull all completed responses per form type (limit 200) and
  filter client-side. Ask the intake team to add the parameter — turns the
  lookup from `O(all org responses)` to `O(1)`.
- The compliance call is **synchronous** inside `accept`. Slow intake = slow
  accept. If this matters, options in increasing order of work:
  1. Short-TTL cache on the per-`(intake_patient_id, form_type)` verdict.
  2. Precompute compliance when a queue entry is created and stash on the
     entry; revalidate on a TTL.
  3. Move the check off the accept path entirely: a background job marks
     entries `compliant: true` and `accept` only books pre-cleared entries.

## What's pending: Check-in / queueing app

`docs/integration-contracts.md` (sc-7hs) is the decision record. The check-in
app **is the queueing service** — the same external system patients sign
into when arriving for an appointment. It owns patient registration and
emits the sign-in event that creates the visit.

Decision: **wait for the real OpenAPI spec, then generate a client. Don't
build speculative stubs.** Today, queue entries are created via
`POST /api/v1/queue_entries` (admin / manual / test flows). When the check-in
spec lands the work is:

1. Generate a client from the spec.
2. Add a webhook receiver under `/api/v1/webhooks/check-in/...`.
3. Add a periodic reconcile pull against the REST API.
4. The check-in app references patients by their canonical `client_id` (see
   "Patient identity" below), distinct from `intake_patient_id`.

### Patient identity

Three external systems reference the same human; scheduling owns the
canonical identity:

| Field on `patients`    | Owned by         | Used by                          |
|------------------------|------------------|----------------------------------|
| `client_id` (uuid)     | **scheduling**   | All inter-service references     |
| `external_id` (string) | check-in/queueing | Map check-in app's patient id    |
| `intake_patient_id` (uuid) | intake-form  | Compliance gate lookup           |

`client_id` is auto-generated on patient create if not supplied; it is
**not** the EMR record id. External systems integrate by exchanging
`client_id` plus their own source-specific id.

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

A note on the host: inside an Apple `container` instance, `localhost` is the
container itself. Use the host gateway IP (`192.168.66.1` on the `default`
network) to reach services on the macOS host. If intake is in a sibling
container on the same network, point at its container hostname or IP instead.

```sh
# 3. Set required_form_types on a diagnosis.
curl -X PATCH http://localhost:4000/api/diagnoses/1 \
  -H 'content-type: application/json' \
  -d '{"diagnosis":{"required_form_types":["stroke-consent"]}}'

# 4. Create a patient with the intake UUID.
curl -X POST http://localhost:4000/api/patients \
  -H 'content-type: application/json' \
  -d '{"patient":{"name":"Jane Doe","intake_patient_id":"<real-uuid>"}}'

# 5. Create a queue entry and accept.
#    Expect: 200 if compliance passes, 422 with missing_form_types if not,
#            503 if intake is unreachable.
```

Watch the matcher audit log at `GET /api/routing_decisions` — every
accept attempt appears there with a rationale. Watch the lifecycle log
at `GET /api/v1/visit_events?visit_id=<id>` for the full timeline of a
visit.

## Open integration work (beads)

Pending feature work that affects integration shape. Track via `bd show
<id>` in the scheduling workspace.

**Auth & lifecycle**

| Bead     | Scope                                                                                                       |
|----------|-------------------------------------------------------------------------------------------------------------|
| `sc-6ea` | Unified OAuth auth system. Service-to-service + per-role human auth. Once landed, `actor_type`/`actor_id` come from the bearer token instead of the request body. |
| `sc-7hu` | Queue-entry state machine extensions: `scheduled`, `cancelled`, `no_show`, `discharged_with_followup`. Adds new event types to `visit_events`. |
| `sc-kub` | Service-to-service trust model (blocked-by `sc-6ea`).                                                       |
| `sc-ry7` | Idempotency-key handling for sign-in / disposition / outbound (blocked-by `sc-6ea`).                        |
| `sc-ais` | Replay job for queue entries stuck on `compliance_unavailable` / `no_eligible_office`.                      |
| `sc-nm5` | Patient-facing notifications (SMS / email) for follow-ups.                                                  |

**Integration surface gaps**

| Bead     | Scope                                                                                                       |
|----------|-------------------------------------------------------------------------------------------------------------|
| `sc-qsr` | Outbound webhooks for visit / queue / handoff events — so integrators don't have to poll.                   |
| `sc-s7u` | Cursor pagination on every list endpoint.                                                                   |
| `sc-2y8` | Unify error response envelope (`{"error": {"code", "message", "details"}}`).                                |
| `sc-c41` | Rate limiting per token / per service (blocked-by `sc-6ea`).                                                |
| `sc-r5n` | External real-time subscription endpoint (SSE / WebSocket, blocked-by `sc-6ea`).                            |
| `sc-ckz` | Wait-time / queue-position read API for the queueing-service patient UI.                                    |
| `sc-jma` | Document the recommended generated-client / SDK toolchain.                                                  |
| `sc-j2s` | Cross-resource query / GraphQL story (deferred).                                                            |
