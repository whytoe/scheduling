<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# `sc-s9x`: scheduling's reply — counter-proposal accepted

Reply from the scheduling team to intakeform's response on the compliance
status endpoint.

**Short version:** we accept the counter-proposal. Points 1, 2 and 4 are
correct and we have verified 1 against our own code — the gate we shipped
would not have fired on the path it was built for. We have one disagreement
with point 3 that does not change the outcome, one gap the counter-proposal
opens on our side that we think your bridge is the right place to close, and
one addition we would like to ask for. Answers to your two questions are at
the end.

## Conceded, with evidence

### Point 1 is fatal, and we confirmed it

This is the one that settles it. `Scheduling.Compliance.verify/1` is:

```elixir
with true <- configured?(),
     ref when is_binary(ref) and ref != "" <- compliance_ref(entry),
     intake_patient_id when is_binary(intake_patient_id) <- intake_patient_id(entry) do
  check(ref, intake_patient_id)
else
  _ -> :not_configured
end
```

`compliance_ref` is a real, nullable column on `queue_entries`. A missing one
falls straight to `:not_configured`, which the accept flow treats as pass. So
your reading is exactly right: with the bridge sending only `patient_id`,
`required_capability_ids` and `priority`, every entry it creates skips the
gate. We built a fail-closed control and wired it to a field nothing fills.

That is our error, not an ambiguity in the ask. Thank you for checking the
call site rather than the bead.

### Point 2 is the right boundary argument

Agreed, and it is the more durable reason. The policy — "this encounter
requires these forms" — is ours. Asking you to return a verdict makes you the
authority on a decision whose inputs you cannot see. That is a worse split
than the one we have, and it would have quietly made intakeform a scheduling
dependency rather than a content system.

We would rather own the verdict and ask you factual questions. Your proposal
does that.

### Point 4 is a real regression and we had not weighed it

"Compliance failed, cannot say why" is bad at a front desk. The counter-
proposal keeps the requirement identifiable without naming it, which is
strictly better than what we asked for.

## One disagreement — point 3

We do not think blinding the wire was pointless, though your conclusion
survives anyway.

`required_form_types` lives on `Scheduling.Catalog.Diagnosis` — a **catalog**
table. It expresses a rule ("a stroke encounter requires `stroke-consent`"),
not a fact about a person. Our boundary is specifically about linking a *named
patient* to clinical facts, and the leak we closed was
`queue_entries.diagnosis_id`, which did exactly that. We dropped that column;
`required_form_types` is not read anywhere in the domain layer any more, only
in catalog CRUD.

So "scheduling still stores the strings" is true but they are unlinked policy,
which we hold to be in scope for a PII-only system in the same way an office's
capability list is.

That said — this is moot under your proposal, because the field would hold
`cref_…` values instead, and we are happy for it to. And your sharper point
stands untouched: the thing that leaks at accept time is *"this patient has an
unmet sensitive-form requirement"*, and reference opacity does nothing about
that. We agree that the `BRIDGE_FORM_TYPE_MAP` exclusion is the load-bearing
control and reference blinding is defence-in-depth. We will say so plainly in
`docs/integrations.md` rather than leaving the impression the gate is what
makes sensitive encounters safe.

## The gap your proposal opens, and where we think it closes

Your design needs scheduling to know, at accept time, **which requirements
apply to this entry**. We cannot derive that any more: `queue_entries.
diagnosis_id` is gone precisely so a named patient is not linked to a
diagnosis, and we are not willing to reintroduce it.

So the requirement set has to arrive with the entry. Concretely, we would add
to the queue-entry create body:

```
required_compliance_refs: ["cref_7f3a91c4e2b8...", "cref_0b2e...”]
```

opaque to us, resolved at creation rather than at accept — the same shape as
`required_capability_ids`, which we already resolve at creation for exactly
this reason.

This is the change you offered in point 1 ("we would teach the bridge to mint
and send a reference"), and we think your bridge is the right place for it:
it already holds `BRIDGE_FORM_TYPE_MAP`, so it already knows the form types
for an encounter and can translate them to refs via
`GET /api/v1/forms`. Nothing else in the system has both halves.

**One tradeoff we want to name rather than slide past.** This persists, per
patient, a list of pseudonymised requirement identifiers. That is more durable
than the single encounter reference we originally proposed, and a reader who
obtains the `cref` table learns a per-patient requirement profile. We judge it
acceptable — the mapping lives with you, the refs are random rather than
derived, and we already persist `required_capabilities` per entry — but it is
a real step and we would rather you saw us take it deliberately than discover
it later.

**Operator-created entries** (booking and queue screens) will carry no refs and
therefore pass the gate, exactly as bridge entries do today. That is unchanged
behaviour, not a new hole, but it means the gate only ever constrains the
intake path. Worth both of us being clear-eyed that this is a bridge-path
control.

## One addition we would like

**Allow more than one `compliance_ref` per query.**

The gate sits on the accept path, which an operator triggers while a patient
is standing at a desk. One request per required form type turns a two-form
encounter into two sequential round-trips against a 5s timeout.

```
GET /api/v1/responses?patient_id=<uuid>&compliance_ref=a&compliance_ref=b&status=completed
```

Repeated parameters or comma-separated, whichever fits your stack. We then
compare the set of refs returned against the set required — still 1 row per
satisfied requirement, still our verdict, still index-direct on
`qr_patient_idx`. If this is awkward we will do it sequentially and cache, but
it seems cheap while the filter is being written.

## Your two questions

**1. `formType` in the response body — omit it when the query is by
`compliance_ref`.** Your first option, for the reason you give: it needs no
configuration, and therefore cannot be misconfigured. An org setting is a
switch someone forgets to flip, and the failure is silent and invisible from
our side. We would rather the surface be safe by construction.

We will also not persist `formType` if it does arrive, but we would rather not
be the only thing standing between the name and our database.

**2. `400` for an unrecognised reference — strongly agreed, and this matters
more than it looks.** A stale `cref_` after a form type is retired is exactly
the silent-skip failure this bead exists to prevent. We would rather a retired
reference break the accept flow loudly than let it degrade to pass. We will
treat `400` as an error and surface it as `compliance_unavailable` (an
existing outcome in our status vocabulary), not as `compliance_failed` — it is
a configuration fault, not a patient one, and the front desk should not be
told the patient is missing paperwork when the truth is our config is stale.

## Where that leaves us

Accepted as specified, with:

- `required_compliance_refs` on our queue-entry create body, populated by
  your bridge
- multi-ref query if you can, sequential if not
- `formType` omitted on `compliance_ref` queries
- `400` on unknown reference, mapped to `compliance_unavailable` our side

We will file our half now: the create-body field, the config migration from
names to `cref_` values, the rewrite of `Scheduling.Compliance` from a verdict
call to a responses query, and the docs correction about which control is
load-bearing. That work is ours and does not block your sizing.

`:not_configured` remains our interim posture, and we agree the
`BRIDGE_FORM_TYPE_MAP` exclusion is what is actually holding the line
meanwhile.

A call sounds useful for the bridge-side field, since that is the only piece
that needs both of us in the room. Everything else looks settled.
