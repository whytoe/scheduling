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
scheduling ──► intake:  GET /responses?patient_id=<uuid>&compliance_ref=<opaque>&status=completed
scheduling ◄── intake:  [] | [ {...} ]      (zero rows = unmet)
```

Intake owns the mapping from reference to form — legitimately, since it owns
the forms — and mints a random `cref_` per `(organization_id, form_type)`.
Random rather than derived, so a reference cannot be recovered by hashing
plausible form-type names. Scheduling holds only the references an encounter
requires, resolved at creation, and compares what came back against what it
required.

**Scheduling computes the verdict, and that is deliberate.** We first asked
intake for a pass/fail endpoint. They declined, correctly: the policy about
which forms an encounter requires is ours, so a verdict endpoint would have
made intake the authority on a decision whose inputs it cannot see — and a bare
pass/fail cannot be explained to a patient at a desk. Keeping the verdict here
means we can say *which* requirement is outstanding. The full exchange is in
`docs/intake-compliance-reply.md`.

**The `compliance_ref` filter is not built yet.** It is a request to the intake
team, analogous to the `?patient_id=` filter they added for `sc-c9j`. Until it
ships the gate stays unconfigured, `Compliance.verify/1` returns
`:not_configured`, and entries pass — the same fail-open posture as an
unconfigured intake.

Note the limit of this control: it stops scheduling *storing* form-type names,
but a block against a named patient still says "this patient has an unmet
requirement". The control that keeps sensitive encounters out of scheduling
entirely is the intake bridge's exclusion list, not this gate. See
`docs/integrations.md`.

## Reading from ac-core

`Scheduling.Core.Client` is the only way patient data enters this system from
the core API, and it is a **projection boundary**, not a pass-through.

Every object in `ac-core-swagger.json` is declared `additionalProperties:
true`. The live API may already return fields the spec does not list, and may
start returning more without a spec change. So each response is projected
field by field into a map the client constructs, and the raw body is discarded
there. Nothing downstream ever sees it.

From a patient we keep `id`, `practiceId`, `firstName`, `lastName` — enough to
correlate the record and call the right person. We drop `mrn`, `dateOfBirth`,
`phone` and `email`: all PII we *could* hold, none of it needed. Minimal
exposure is the rule, not just "no PHI".

Two consequences worth stating:

- **Never `Map.take/2` or `Map.merge/2` a core response.** The projection has
  to name its fields, which is why the client returns snake_case atom keys —
  a projection cannot be produced by merging a decoded JSON map.
- The token requests **read scopes only** (`core:patients:read`,
  `core:organizations:read`). `core:patients:write` is deliberately absent:
  scheduling projects patient data, it does not author it.

`test/scheduling/core/client_test.exs` asserts the allowlist directly, feeding
the client a response stuffed with unwanted and undocumented fields and
checking none survive.

## Opaque service codes

External systems name a service by its catalog **`code`**, not by a row id and
not by a clinical label:

    POST /api/v1/queue_entries
    {"queue_entry": {"patient_id": 1, "service_code": "svc_7a2f"}}

Scheduling resolves the code to the capabilities that service requires, records
those on the entry, and **discards the code**. Neither side has to put a
clinical label on the wire, and the entry ends up holding equipment only —
the same outcome as the `diagnosis_id` path, reached without an internal id
leaking into an external contract.

Codes should be opaque (`svc_7a2f`), not descriptive (`stroke-workup`). A
descriptive code travelling alongside a patient id is a clinical label in
everything but name, and it would appear in request logs at both ends. The
catalog's human-readable name stays local, where it is a rule rather than a
patient fact.

This is the same shape as `compliance_ref`, in the other direction: an opaque
token in, a resolved answer out, and the meaning owned by whichever system
legitimately holds it.

## Deleting catalog rows

Capability joins cascade. For `office_capabilities` and
`diagnosis_capabilities` that is correct — an office stops offering something,
a routing template stops requiring it, and nothing about a patient changes.

For `appointment_capabilities` and `queue_entry_capabilities` it is not.
Cascading there does not make the work unservable; it makes it require
**nothing**, silently. `Scheduling.Catalog.delete_capability/1` refuses while
live work requires the capability, for that reason.

The general shape: **cascading through catalog references is fine, cascading
through patient-attached references is not.** Anything new that joins a
capability, an office or a service to a patient row should decide this
deliberately rather than inheriting `on_delete: :delete_all` by habit.

## If you need to add clinical data

Don't. Put it in the EMR and reference it by an opaque id, the way
`compliance_ref` works. If routing genuinely needs a new signal, model it as a
capability (equipment) rather than a condition.

Talk to legal/compliance before plumbing anything through that names a clinical
purpose — particularly for specially-protected categories (behavioural health,
substance use, reproductive health, HIV status), where even the *existence* of
an encounter is sensitive.
