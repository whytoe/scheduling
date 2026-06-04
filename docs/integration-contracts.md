# Integration Contracts — External Check-in & Forms

**Status:** Design brief / working assumption. This is the decision record for
`sc-7hs` and the working contract for its fast-followers `sc-bd8` (check-in
ingest) and `sc-5ed` (forms requirement details).

**Update 2026-06-04:**

- The **check-in app == the queueing service** — the same external system
  patients sign into when arriving for an appointment. It is the workflow's
  entry point. (Previously these were considered separately.)
- The **forms-management app == the intake-form system**. Its REST API and
  compliance-gate integration are now implemented; see `integrations.md`.
- `sc-5ed` is therefore effectively delivered (the diagnosis-driven required
  forms gate lives at accept time, not ingest time). `sc-bd8` remains held
  pending the check-in/queueing app publishing its spec.

## Context

Scheduling is the clinical patient-flow intake service (Phoenix/LiveView +
Ecto/Postgres). It does **not** own patient registration or intake forms —
those live in two external applications:

- **Check-in app** — owns patient registration and physical check-in. Talks to
  us over a **webhook** (real-time check-in events) plus a **REST** API
  (reconcile / backfill).
- **Forms-management app** — owns intake forms and the captured "requirement
  details" for a patient. Exposes a **REST** API.

Scheduling's job: take a checked-in patient, determine the capabilities their
visit requires, best-fit match them to an office with spare intake capacity,
and run them through the queue lifecycle.

## Decision

**Consume the real OpenAPI spec + webhook payload schema published by the
external apps** — generate/typify the client from the spec. **Do not build
speculative stubs.** `sc-bd8` and `sc-5ed` are *fast-followers*: dispatch them
as soon as the external spec + webhook schema are available.

The shapes below are the **working assumption** until that spec lands; reconcile
them against the actual spec on arrival. This is a design doc, not stub code —
no client is built against these guesses.

**Why:** the external app is actively producing its spec. Building against
guessed contracts now would create rework when the real spec differs; waiting
for it and generating the client is cheaper and correct.

## Domain touchpoints (current schema)

| Schema | Relevant fields | Role in integration |
|--------|-----------------|---------------------|
| `Patient` | `name`, `external_id` | Minimal record; registration owned by check-in app. `external_id` links to the check-in app's patient id. |
| `QueueEntry` | `status` (`waiting → assigned → in_service → completed`), `priority`, `patient`, `diagnosis`, `assigned_office`, `required_capabilities` | The unit of work. "BOTH model": required capabilities derive from `diagnosis` or an explicit per-entry override. |
| `Office` / `OfficeCapability` | capabilities, intake capacity / load | Best-fit matching target. |
| `Capability` / `Diagnosis` / `DiagnosisCapability` | catalog | Maps a diagnosis to default required capabilities. |

## Integration 1 — Check-in app → ingest (`sc-bd8`)

Goal: ingest checked-in clients and get them into rooms (offices).

### Inbound webhook (check-in → scheduling) — *working assumption*

- **Event:** `patient.checked_in`
- **Proposed payload:** `external_patient_id`, `name`, `checked_in_at`, and a
  reason/`diagnosis_code` hint (if the check-in app captures it).
- **Behaviour:** upsert `Patient` by `external_id` → create a
  `QueueEntry{status: :waiting}` → derive `required_capabilities` (from
  diagnosis, or defer to forms — see below) → run best-fit office matching →
  assign.
- **Security:** verify the webhook signature per the external app's scheme
  (assume HMAC over the raw body until the spec says otherwise).
- **Idempotency:** dedupe on the external event id (or
  `external_patient_id` + `checked_in_at`); webhook delivery is assumed
  at-least-once.

### REST (scheduling → check-in) — *working assumption*

- Reconcile / backfill checked-in clients missed by webhooks.
- Optional callback: notify the check-in app once a patient is roomed/assigned.

## Integration 2 — Forms-management app → requirement details (`sc-5ed`)

Goal: accept the requirement details that drive capability matching.

### REST (scheduling → forms) — *working assumption*

- `GET` requirement details for a patient/form → map to a `diagnosis` and/or an
  explicit `required_capabilities` set on the `QueueEntry`.
- Pulled at ingest (or on demand) to refine matching when the check-in event
  alone doesn't carry the clinical requirements.

## Open questions (resolve against the real spec)

1. **Auth** — scheme for the inbound webhook and the outbound REST calls
   (API key / OAuth client-credentials / signed HMAC header)?
2. **Code mapping** — do the external diagnosis/capability codes map 1:1 to our
   `Catalog`, or do we need a translation layer?
3. **Delivery guarantees** — webhook retries / ordering? (Drives the
   idempotency design.)
4. **Division of responsibility** — does check-in push the diagnosis, or only
   identity (with forms supplying the clinical requirements)?
5. **Reconciliation endpoint** — shape of the check-in REST pull/backfill.

## Unblock & dispatch plan

1. **Obtain** the external OpenAPI spec + webhook payload schema. *(Blocker —
   external dependency.)*
2. **Generate/typify** the client(s) from the spec.
3. **Reconcile** this doc's working-assumption shapes against the real spec.
4. **Dispatch** `sc-bd8` (check-in ingest: webhook handler + REST reconcile +
   matching) and `sc-5ed` (forms requirement pull) as fast-followers.

## Dependency status

- `sc-7hs` (this decision) — recorded; waiting on the external spec.
- `sc-bd8`, `sc-5ed` — held pending the spec.
