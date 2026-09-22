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
                                │     GET /responses?compliance_ref=…&status=completed
                                │     (opaque refs out, rows back; we decide)
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

#### What your token must carry

Three things, checked in this order. All three are required — a token that
authenticates is not automatically a token that may act.

| # | Requirement | Failure |
|---|---|---|
| 1 | The provider says it is live | 401 `invalid_token` |
| 2 | `aud` names this deployment | 401 `invalid_token` |
| 3 | A role in `astrum_roles` we recognise | 403 `forbidden` |

**1 — live.** Either the token validates as a JWT against the realm's JWKS, or
the realm's introspection endpoint reports it `active`. Which of those applies
is the provider's choice, not yours: ac-core issues **opaque** access tokens,
so every token there takes the introspection path. Nothing about that changes
what you send.

**2 — audience.** This is the one that catches people, because a provider does
not necessarily name *us* in a token minted for *your* client. Keycloak needs
an explicit audience mapper; other providers vary. Whatever value your tokens
carry in `aud`, it must appear in this deployment's `OIDC_API_AUDIENCES`
(comma-separated) — the deployment's own client id is always accepted, and
anything else has to be listed. Getting this wrong looks exactly like a bad
credential, so check it before rotating anything.

If your provider's introspection response omits `aud` entirely, this check
cannot run and is skipped; see `auth.md` for what that costs.

**3 — role.** `astrum_roles` must contain `service` (or `operator`, or
`admin`). A machine client does not get one by default in most realms — it has
to be granted, and a client-credentials token minted without it will
authenticate and then be refused on every write. That is a 403 rather than a
401, which is the fastest way to tell this case apart from the two above.

> **Against ac-core this is currently unsatisfiable**, and it is the reason no
> service can call this API yet. A verified client-credentials token from
> ac-core carries no `astrum_roles` and no other claim describing authority, so
> it authenticates and is then refused everything. The fix belongs in ac-core —
> a scheduling-namespace scope, or the role claim populated on machine tokens —
> and is asked for in `ac-core-asks.md`. Deciding here which clients may act,
> from a list of client ids, would put a second source of truth for
> authorisation in this deployment's configuration.

The claim path is configurable (`OIDC_ROLE_CLAIMS`) and several are searched,
so `roles`, `realm_access.roles` and
`resource_access.<client_id>.roles` work too — every one present is unioned.

#### Checking it before you integrate

```sh
TOKEN=$(curl -s -X POST "$OIDC_ISSUER/oauth/token" \
  -d grant_type=client_credentials \
  -d client_id=... -d client_secret=... | jq -r .access_token)

# What the realm thinks your token is. Confirms 2 and 3 without involving us.
curl -s -X POST "$OIDC_ISSUER/oauth/introspect" -d "token=$TOKEN" | jq '{aud, astrum_roles, active}'

# Then the real thing. 401 means 1 or 2; 403 means 3.
curl -si "$SCHEDULING_URL/api/v1/board" -H "Authorization: Bearer $TOKEN" | head -1
```

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
- **Writes accept `Idempotency-Key`.** Send the same key to retry a request
  safely: the second call returns the **first call's response**, id included,
  and the write happens once. See "Retrying safely" below.
- The actor recorded on each `visit_event` comes from the **token** —
  `sub` for a user, the client id for a service account. `actor_type` and
  `actor_id` in the request body are ignored.

### Rate limits

`/api/v1` allows **120 requests per minute per bearer token**. Over that you get
`429` with `Retry-After` in seconds and an error code of `rate_limited`:

```json
{"error": {"code": "rate_limited",
           "message": "Too many requests. Retry in 24s.",
           "details": {"retry_after_seconds": 24}}}
```

**Honour `Retry-After`.** A client that backs off on it is the difference
between a limiter that calms a retry storm and one that shapes it into a
tighter storm.

Two things worth knowing:

- **The quota is per token.** Each of your credentials gets its own allowance,
  so one runaway process does not spend another's — and nothing you do consumes
  another integrator's.
- **Invalid tokens count too.** The limit applies before authentication, because
  a token that fails validation costs us more than one that succeeds. If you are
  seeing `429` alongside `401`, the fix is to stop retrying the bad credential,
  not to ask for a higher limit.

Windows are fixed rather than sliding, so a short burst may briefly exceed 120
across a window boundary. That is deliberate slack, not a guarantee to build on.

### Retrying safely

A request that times out leaves you unable to tell whether it happened. For
`POST /queue_entries` that is the difference between two queue entries for one
arrival and none at all. Rather than guess, repeat the request with the same
`Idempotency-Key`:

```sh
curl -s -X POST "$SCHEDULING_URL/api/v1/queue_entries" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: arrival-9f3c1b" \
  -H "content-type: application/json" \
  -d '{"queue_entry": {"patient_id": 42}}'
```

The second call returns the first call's response — **the same body and status,
including the id of whatever was created** — and nothing is written twice. A
replay carries `idempotency-replayed: true` so you can tell it apart without
diffing.

Use any stable value your side already has. An appointment id or an arrival id
is better than a fresh UUID, because it stays the same across a process restart
that loses your in-memory state — which is exactly when you most need it.

| Case | Status | `error.code` |
|---|---|---|
| Same key, first request still in flight | 409 | `idempotency_key_in_progress` |
| Same key, **different** request body | 422 | `idempotency_key_reuse` |
| Header present but unusable | 422 | `idempotency_key_invalid` |

409 means wait and try again; 422 means retrying will not help.

Three things worth knowing:

- **It is opt-in.** No header, no protection — we do not invent a key for you,
  because we cannot know which two requests you consider the same.
- **`5xx` responses are not cached.** A server error is not a decided outcome,
  and pinning you to a failure you can never retry past is the opposite of the
  point. Your retry becomes a real attempt.
- **Keys are scoped to the caller and held for 24 hours.** Two services may use
  the same key without colliding, and neither can read back the other's
  response.

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

`diagnoses.required_compliance_refs` (renamed from `required_form_types`) is
catalog data: the references a pathway requires by default. It **is** read, but
at *creation* — expanded onto the entry alongside the default capabilities and
then the diagnosis is discarded. That is what lets the gate work at accept time
without the entry holding a diagnosis, and it is why an entry raised from a
booking screen is gated the same as one from the bridge.

### Behavior

`POST /api/v1/queue_entries/:id/accept`:

1. **Compliance gate** runs first, when all of: `INTAKE_API_KEY` is set, the
   entry has at least one `required_compliance_refs` value, and the patient has
   an `intake_patient_id`. Any of those missing → the gate is skipped.
2. **Self-check** (see below) — before any verdict is reached, scheduling
   establishes that intake is really filtering by `compliance_ref`. If it
   cannot, the gate refuses to run and the accept is `503
   compliance_unavailable`.
3. For each required reference,
   `GET {INTAKE_API_URL}/responses?patient_id=<uuid>&compliance_ref=<ref>&status=completed&limit=1`
4. One or more rows → that requirement is satisfied; zero rows → it is unmet.
   Scheduling collects every unmet reference rather than stopping at the first,
   so the whole outstanding set can be reported at once.
5. **Matcher** runs next (unchanged — best-fit office with free capacity).

### Proving the filter is a filter

Step 3 reads only the **row count** of intake's answer. Nothing in that answer
says which of the four query parameters intake honoured — so an intake that
accepts `compliance_ref` and ignores it silently turns the query into *"has
this patient completed any form at all"*, and a patient who filled in something
unrelated satisfies every requirement on the entry. If `patient_id` were the
ignored one instead, any patient in the organisation completing that form would
satisfy it for everyone.

Both directions fail **open**, on the one path the gate exists to close, and
neither errors nor logs. The reassuring answer and the broken answer are the
same bytes.

So before the gate reaches a verdict, scheduling asks a question whose only
honest answer is "nothing":

```
GET {INTAKE_API_URL}/responses?compliance_ref=cref_<never+minted>&status=completed&limit=1
```

| Intake's answer        | Read as                                                     |
|------------------------|-------------------------------------------------------------|
| `400`                  | The reference reached a lookup and was rejected — the settled behaviour for an unknown reference. The same query is then repeated **without** `compliance_ref`; only if that one succeeds was the `400` about the reference and not about the query being malformed. |
| `200`, no rows         | Consistent with the filter being applied. Weaker: an intake holding no completed responses at all answers identically. |
| `200`, one or more rows | `compliance_ref` is not being applied. **The gate refuses to run.** |
| anything else          | Nothing established. The gate refuses to run.               |

A refusal is `503 compliance_unavailable` with an `Compliance gate REFUSING TO
RUN` line in the log, and the entry stays waiting — the same fail-closed path an
unreachable intake takes. It is never `422 compliance_failed`: the patient is
not the problem.

Refusing is the point. A gate that cannot be shown to be gating anything is
worse than no gate, because it appears on the deployment checklist as a control
while passing everyone.

**No `patient_id` on the probe**, deliberately, though every real query carries
one. A second narrowing parameter would let an intake that ignores the
reference still answer with an empty list.

**Once per fifteen minutes, not per request.** The answer is established on the
first accept that would actually consult intake, then held. Per request would
double our traffic to intake to re-establish a fact that does not move between
two accepts; at boot would make intake's availability a startup dependency of
scheduling for no gain, since nothing is being decided until the first accept
arrives. Failures are never cached, so an intake that ships the filter starts
working without a restart here. The expiry is not decoration: it bounds how
long a pass granted under the weaker `200`-with-no-rows condition survives
after intake records its first response.

Outcomes (all written to the `routing_decisions` audit log with a
human-readable rationale):

| Outcome                                | HTTP | Body                                                                       | Entry state |
|----------------------------------------|------|----------------------------------------------------------------------------|-------------|
| Assigned                               | 200  | `QueueEntry` (status=`assigned`)                                           | assigned    |
| Compliant → matcher had no eligible office | 409  | `error.code = "no_eligible_office"`                                        | waiting     |
| One or more requirements unmet         | 422  | `error.code = "compliance_failed"`, `error.details.unmet_compliance_refs`  | waiting     |
| Intake unreachable, or a reference it does not recognise | 503 | `error.code = "compliance_unavailable"`, `error.details.reason` | waiting     |

**Fail-closed**: an unreachable intake blocks new bookings, and so does a
reference intake cannot resolve — passing an unknown requirement through the
gate would defeat the point. Bookings resume automatically when intake
recovers.

Note the two are reported differently on purpose. An unmet requirement is a
`422 compliance_failed` — the patient genuinely owes a form. An unrecognised
reference is a `503 compliance_unavailable`, because a stale `cref_` left
behind after a form type was retired is *our* configuration being wrong, and
the front desk must not be told a patient owes paperwork they do not owe.

> **This filter does not exist yet.** `compliance_ref` on `/responses` is a
> request to the intake team, analogous to the `?patient_id=` filter they added
> for `sc-c9j`, and they have agreed to it in principle — see
> `docs/intake-compliance-reply.md`. Until it ships, leave `INTAKE_API_KEY`
> unset, which skips the gate. Setting it against an intake that predates the
> filter no longer passes everyone silently — the self-check above refuses and
> says so — but it does mean every accept that requires compliance fails
> closed.

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
a policy asking humans to compensate for a design flaw. The field is now
`required_compliance_refs` and holds opaque `cref_` values minted by intake, so
scheduling never receives the form types and cannot leak them;
`test/scheduling/phi_boundary_test.exs` asserts it at each egress path. The
diagnosis catalog screen flags any value that is not reference-shaped, which
catches a form name typed by hand — including classes nobody thought to list.

### Which control is actually load-bearing

Worth being blunt about, because it is easy to over-credit the gate.

Reference blinding stops scheduling **storing** form-type names. It does not
stop the more interesting fact leaking: a `compliance_failed` outcome against a
named patient says *"this patient has an unmet requirement"*, and that is
equally true whether the reference is opaque or not. A reference is a pseudonym
with a stable mapping — anyone holding both sides once learns the table
permanently.

The control that keeps sensitive encounters out of this system altogether is
the **exclusion list on the intake bridge** (`BRIDGE_FORM_TYPE_MAP`): a form
type left out of it never produces a queue entry here at all. That is a real
boundary. Reference blinding is defence-in-depth stacked on top of it, and
should be evaluated as such rather than as the thing that makes the gate safe.

This framing is intakeform's, from their reply to `sc-s9x`, and they were right
to push on it — see `docs/intake-compliance-reply.md`.

For the same reason `queue_entries` no longer has a `diagnosis_id`. A diagnosis
may be passed to `POST /api/v1/queue_entries` as a convenience — it is expanded
to that diagnosis's default capabilities and discarded — but the association is
never stored.

### Known limitations

- The compliance call is **synchronous** inside `accept`, and currently issues
  one request per required reference. Slow intake = slow accept. Batching needs
  intake to return the reference on each row — without that a multi-ref query
  says how many requirements are met but not which, which is not an answer the
  gate can use. Requested; `Scheduling.Compliance.Client.satisfied_refs/2` is
  already list-shaped so the swap is one function. If it bites sooner:
  1. Short-TTL cache on the per-`(intake_patient_id, compliance_ref)` result.
  2. Precompute at entry creation and revalidate on a TTL.
  3. Move the check off the accept path entirely: a background job marks
     entries pre-cleared and `accept` only books those.
- The gate is **skipped when an entry requires no references**. Requirements are
  resolved at creation — from `service_code`/`diagnosis_id` against the catalog,
  or from an explicit `required_compliance_refs` — so an entry created with
  neither passes. Fail-open, matching the unconfigured-intake default.
- An **unrecognised reference is not a block**. Intake answers `400`, which maps
  to `compliance_unavailable`, not `compliance_failed`. A stale `cref_` left
  after a form type is retired is our configuration being wrong, and the front
  desk must not be told a patient owes paperwork they do not owe.
- The self-check's weaker pass condition is **`200` with no rows**, which an
  intake holding no completed responses at all also produces. It is not a hole
  that passes anyone: in that state every real query returns nothing too and
  the gate blocks. But it is why the answer expires rather than being kept, and
  it is why a `400` for an unknown reference (ask 1 in
  `docs/intakeform-asks.md`) is worth more than it looks — it is the only
  answer that is positive proof rather than an absence.

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

The other list endpoints — **capabilities, diagnoses, patients, offices,
visits, queue_entries, handoffs** — paginate the same way
(`?limit=N&after=<cursor>`, `X-Next-Cursor` header), with one difference: each
keeps its own natural ordering (catalogs by name, visits by start time, the
queue by priority then arrival), so `after` there is an **opaque cursor** rather
than a bare id. Echo the `X-Next-Cursor` value back verbatim; do not parse it.
`queue_entries?status=all` walks a single oldest-first order across both status
groups (the unpaginated version returned waiting-then-active).

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
