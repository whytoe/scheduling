# Data boundary

**Scheduling carries PII. It does not carry health data.** Clinical data lives
in the EMR (ac-core, `core:emr:*`).

This is a hard constraint, not a preference. It shapes the schema, the API and
the audit log, and it is the reason `queue_entries` has no diagnosis and the
compliance gate sends an opaque reference.

## The line

Scheduling knows **who, where, when, and what equipment**. It does not know
**why**.

| | Allowed here | Why |
|---|---|---|
| Patient name, ids | ✅ PII | Needed to call the right person to the right room |
| Arrival, wait, service times | ✅ | Operational |
| Office / room, capacity | ✅ | Operational |
| Equipment requirement ("CT scanner") | ✅ | Routing cannot work without it |
| Diagnosis, condition, clinical reason | ❌ PHI | Belongs in the EMR |
| Intake form types ("stroke-consent") | ❌ PHI | Names a clinical purpose |
| Form answers, notes, results | ❌ PHI | Never touched this system |

### Why equipment is on the allowed side

A scheduling system that knows nothing about what a patient needs cannot route
them. "CT scanner" is a resource requirement — weaker than a diagnosis, and
operationally unavoidable.

It is not *nothing*, and it should be treated with care: a capability named
after a clinical purpose rather than a piece of equipment would put PHI back in
the queue by the back door. **Name capabilities after equipment and rooms, not
conditions or services.** "CT scanner", "phlebotomy chair", "negative-pressure
room" — not "oncology infusion", not "psychiatric assessment".

## Per table

| Table | Holds | Notes |
|---|---|---|
| `patients` | name + correlation ids | PII. `client_id`, `external_id`, `intake_patient_id` |
| `queue_entries` | patient, status, priority, `compliance_ref` | No diagnosis. `compliance_ref` is opaque |
| `queue_entry_capabilities` | equipment needed | Join to `capabilities` |
| `capabilities` | equipment catalog | Not patient-linked |
| `diagnoses`, `diagnosis_capabilities` | routing templates | **Not patient-linked.** Rules, not facts |
| `offices`, `office_capabilities` | rooms and what they provide | No patient data |
| `visits` | patient, start/end | Encounter timing only |
| `routing_decisions` | patient name, capabilities, chosen office, rationale | Rationale is scrubbed — see below |
| `visit_events` | type, ids, actor, payload | Payload must stay non-clinical |
| `handoffs` | patient name, office name, capabilities | Snapshots for the staff notification |
| `webhook_subscriptions` | url, secret, event types | No patient data |

`diagnoses` is the one that looks like a contradiction. It is a **catalog of
routing templates** — "this pathway needs these capabilities". Nothing links a
patient row to it. `Scheduling.Queue.create_entry/2` accepts a `diagnosis_id`,
expands it to that diagnosis's default capabilities, and discards the
reference. The convenience survives; the association does not.

## The three egress paths

`docs/integrations.md` names the places a clinical detail could escape. Each is
covered by a test in `test/scheduling/phi_boundary_test.exs`:

1. **`routing_decisions.rationale`** — append-only, and read by the
   `/decisions` screen. A compliance failure records
   `"Compliance check failed for reference <ref>"`, never the form types.
2. **`visit_events.payload`** — the `queue_entry.created` payload is
   `%{priority: n}` and nothing more.
3. **Outbound webhooks** — `Scheduling.Webhooks.deliver/2` serialises the visit
   event verbatim, so it inherits (2). This is the widest path: every
   subscriber sees it.

Adding a field to any of these is the moment to re-read this document.

## The compliance gate

The gate used to read `required_form_types` off the entry's diagnosis and send
the form-type names to intake, then write the missing ones into the audit log.
That is the leak `docs/integrations.md` warned about, realised in code.

It now works the other way round:

```
scheduling ──► intake:  GET /compliance/status?reference=<opaque>&patient_id=<uuid>
scheduling ◄── intake:  {"compliant": true|false}
```

Intake owns the mapping from reference to required forms — legitimately, since
it owns the forms. Scheduling passes an opaque token through and receives a
verdict. It cannot leak what it never learns.

**The `/compliance/status` endpoint is not built yet.** It is a request to the
intake team, analogous to the `?patient_id=` filter they added for `sc-c9j`.
Until it ships, entries carry no `compliance_ref`, `Compliance.verify/1`
returns `:not_configured`, and the gate is skipped — the same fail-open posture
as an unconfigured intake.

## If you need to add clinical data

Don't. Put it in the EMR and reference it by an opaque id, the way
`compliance_ref` works. If routing genuinely needs a new signal, model it as a
capability (equipment) rather than a condition.

Talk to legal/compliance before plumbing anything through that names a clinical
purpose — particularly for specially-protected categories (behavioural health,
substance use, reproductive health, HIV status), where even the *existence* of
an encounter is sensitive.
