# Integrations

How Scheduling talks to the world. Two surfaces: the HTTP API we **expose** for
consumers, and the upstream services we **consume**. A third surface
(check-in app) is still pending — see `integration-contracts.md` for the
decision record on why it's held.

## What we expose: Scheduling HTTP API

- **OpenAPI spec:** `GET /api/openapi.json`
- **Swagger UI:** `GET /api/swagger`
- **Health probe:** `GET /api/health` (200 `{"status":"ok"}` / 503 `{"status":"degraded"}`)

The API mirrors every operation the LiveView UI offers — 35 endpoints across
9 tag groups (`capabilities`, `diagnoses`, `patients`, `offices`, `queue`,
`handoffs`, `routing_decisions`, `board`, `health`). Browse the live spec;
this document does not re-derive it.

Conventions:

- Raw JSON bodies, no `data:` wrapper.
- Requests use a per-resource envelope: `{"capability": {…}}`, `{"office": {…}}`.
- Validation errors → **422** with `{"errors": {field: [msgs]}}` (Ecto changeset
  traversal).
- Not found → **404** with `{"error":"not_found"}`.
- Action endpoints under their resource: `POST /queue_entries/:id/accept`,
  `POST /handoffs/:id/acknowledge`.

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
  `POST/PATCH /api/patients`.
- `diagnoses.required_form_types` (`text[]`, default `[]`) — the intake
  `formType` strings that must be on file (status `completed` AND not
  `flagged`) before a patient with this diagnosis can be assigned to an
  office. Set via `POST/PATCH /api/diagnoses`.

Forms-required lives on the **diagnosis**, not the capability, because
compliance is service-defined (what visit is the patient here for?), not
equipment-defined (which room equipment will be used?). This decision is
re-litigable; the join is small.

### Behavior

`POST /api/queue_entries/:id/accept`:

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
`POST /api/queue_entries` (admin / manual / test flows). When the check-in
spec lands the work is:

1. Generate a client from the spec.
2. Add a webhook receiver under `/api/webhooks/check-in/...`.
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

Watch the audit log at `GET /api/routing_decisions` — every accept attempt
(success, no-eligible-office, compliance failure, compliance unavailable)
appears there with a rationale string.
