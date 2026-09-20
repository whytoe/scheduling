# Asks for the intakeform team

Written 2026-09-19. Everything below is either something our code does — cited
by file and line — or is labelled as inference. We have no access to a running
intake deployment, so nothing here is a claim about your behaviour that we
have observed.

This follows the `sc-s9x` exchange (`docs/intake-compliance-reply.md`), where
we accepted your counter-proposal: scheduling sends opaque references, you
answer a factual question per reference, and scheduling computes the verdict.
We then built our half of that design. It is shipped and running in
production, and the gate is switched off, because the endpoint it calls does
not exist yet.

Eight asks. Three block; five do not. The blocking three are small.

---

## Where we got to

Our half landed in `c587c50` (PR #8, deployed 2026-09-04):

- `queue_entries.required_compliance_refs` — the opaque references an
  encounter must satisfy, resolved at creation from the catalog
  (`service_code` / `diagnosis_id`) or taken from an explicit list on the
  create body. `lib/scheduling/queue.ex:186-234`.
- `Scheduling.Compliance` — one `/responses` query per required reference,
  collects **every** unmet reference rather than stopping at the first, and
  computes the verdict here. `lib/scheduling/compliance.ex`.
- `400` is mapped to `{:unknown_reference, ref}` and surfaced as
  `compliance_unavailable` (503), not `compliance_failed` (422) — a stale
  `cref_` is our configuration being wrong, not a patient owing paperwork.
  `lib/scheduling/compliance/client.ex:93`.
- Form-type names are gone from our source entirely. The catalog screen now
  flags anything that is *not* reference-shaped
  (`~r/^cref_[a-z0-9]{8,}$/i`, `lib/scheduling_web/live/diagnosis_live/index.ex:31`)
  instead of matching a hardcoded clinical vocabulary.

`INTAKE_API_KEY` is unset in production, so `Compliance.verify/1` returns
`:not_configured` and every accept proceeds. That is deliberate and it is
where we stay until asks 1 and 2 are answered.

## What we send

This is the whole request, from `lib/scheduling/compliance/client.ex:79-88`:

```elixir
Req.new(
  url: config.base_url <> "/responses",
  params: [patient_id: patient_id, compliance_ref: ref, status: "completed", limit: 1],
  headers: [{"authorization", "Bearer " <> key}],
  receive_timeout: config.http_timeout_ms
)
```

and this is the whole interpretation of your answer
(`lib/scheduling/compliance/client.ex:95-101`):

```elixir
defp handle_response({:ok, %{status: 200, body: body}}, _ref) do
  case rows(body) do
    nil -> {:error, {:unexpected_body, body}}
    []  -> {:ok, false}
    [_ | _] -> {:ok, true}
  end
end
```

Zero rows means the requirement is unmet; one or more means it is satisfied.
We do not inspect the row. `test/scheduling/compliance_http_test.exs:162-200`
pins both the outbound parameter set and the fact that nothing clinical is in
it.

---

## 1. The `compliance_ref` filter on `GET /api/v1/responses` — **blocking**

This is the counter-proposal you made and we accepted, and it is the only
thing standing between the gate and production.

```
GET /api/v1/responses?patient_id=<uuid>&compliance_ref=<cref_…>&status=completed&limit=1
```

Two behaviours were settled in the `sc-s9x` exchange and we are restating them
so they are not lost between threads, not reopening them:

- **`formType` omitted from the response body when the query is by
  `compliance_ref`.** Your first option, because it needs no configuration and
  therefore cannot be misconfigured. We will not persist it if it arrives, but
  we would rather not be the only thing standing between the name and our
  database.
- **`400` for a reference you do not recognise.** We treat it as
  `compliance_unavailable`, never as `compliance_failed`. A retired `cref_`
  must break loudly rather than degrade to a pass.

**What it blocks:** everything. Until it exists the gate is off (`sc-d6z`),
and the fail-closed control we built is not running in production.

## 2. Reject query parameters you do not support — **blocking, and cheap**

This one is new, and it is the reason we are not willing to enable the gate
speculatively before ask 1 lands.

**Verified, on our side:** the client above cannot tell a filtered answer from
an unfiltered one. It sends four parameters and reads only the row count. If
`compliance_ref` is accepted-and-ignored, the query degrades to *"has this
patient completed any form at all"*, and a patient who completed an unrelated
form satisfies every requirement on the entry. If instead `patient_id` were
the ignored one, any patient in the organisation completing that form would
satisfy it for everyone. Both directions fail **open**, silently, on the exact
path the gate exists to close.

**Inference, not observation:** we do not know what your endpoint currently
does with `compliance_ref`, because we cannot reach a deployment. We assume it
is ignored, since the filter is not built — which is precisely the state we
cannot detect.

**Ask:** answer `400` for a query parameter you do not support, on
`/responses` and ideally across `/api/v1`. Then a scheduling deployment
pointed at an intake that predates ask 1 fails loudly at the first accept
instead of quietly passing everyone.

This is worth more to us than it may look from your side. It turns "did the
filter ship in the environment we are pointed at" from a question someone has
to remember to ask into one the system answers by itself, permanently, for
every parameter either of us adds later.

**What it blocks:** enabling the gate without a manual, per-environment
verification that the filter is live. We would rather not build that ritual.

## 3. The bridge sends `required_compliance_refs` on queue-entry create — **blocking**

Agreed in principle in `sc-s9x` ("we would teach the bridge to mint and send a
reference"), recorded here because it is the half that makes the gate fire at
all and it has no ticket we can see.

**Verified:** `Scheduling.Compliance.verify/1` returns `:not_configured` —
which the accept flow treats as a pass — when the entry requires no references
(`lib/scheduling/compliance.ex:73-83`). Your reading in the original reply was
right, and this is the shape of it in the rewritten code as well: an entry
created with no refs and no `service_code` is never gated. The bridge sends
`patient_id`, `required_capability_ids` and `priority`, so every entry it
creates skips the gate today.

Our side is ready and published:

```
POST /api/v1/queue_entries
{"queue_entry": {"patient_id": 1,
                 "required_compliance_refs": ["cref_7f3a91c4e2b8", "cref_0b2e5d9a1c74"]}}
```

The field is in our OpenAPI spec (`lib/scheduling_web/schemas.ex:579-585`),
write-only, and takes precedence over whatever the catalog would have supplied
for a `service_code`. Your bridge is the right place for this because it
already holds `BRIDGE_FORM_TYPE_MAP` and can therefore translate an
encounter's form types to references via `GET /api/v1/forms`; nothing else in
the system has both halves.

**What it blocks:** `sc-5ed` on our side, and in practice the whole gate — ask
1 without this gives us a working endpoint that nothing calls, because
bridge-created entries carry nothing to check.

## 4. Return the reference on each row — **non-blocking**

Batching needs this. A multi-ref query that returns rows without saying which
reference each satisfies tells us *how many* of two requirements are met but
not *which*, and that is not an answer the gate can use.

```
GET /api/v1/responses?patient_id=<uuid>&compliance_ref=a&compliance_ref=b&status=completed
→ [{ "complianceRef": "a", ... }]
```

Repeated parameters or comma-separated, whichever fits your stack. A
reference on the row is not a form name, so this costs nothing against the
boundary.

**What it costs us without it:** the gate sits on the accept path, which an
operator triggers while a patient is at the desk. We issue one request per
required reference, sequentially, against a 5s timeout
(`lib/scheduling/compliance/client.ex:59-77`). Two requirements, two
round-trips. `Compliance.Client.satisfied_refs/2` is already list-shaped, so
swapping in a batch call is a change to one function.

Genuinely non-blocking — we will run it sequentially and cache if this is
awkward.

## 5. Return `patientId` on each row — **non-blocking**

We used to assert this and we dropped it. The pre-rewrite client checked
`patientId == intake_patient_id` on every returned row, described in `c9fef07`
as "belt-and-suspenders against an intake-side filter bug that returned other
patients' rows". The reference-based rewrite reads only the row count, so that
check is gone.

`patientId` is your own identifier for a patient we already hold as
`patients.intake_patient_id`, so returning it tells us nothing new and lets us
restore the assertion. It also makes ask 2's failure mode detectable on the
row rather than only preventable at the parameter.

## 6. What does `status=completed` mean for a flagged response? — **please confirm**

**Verified, and it is our defect as much as a question for you.** Before the
rewrite we filtered client-side on `flagged == false`, because — per
`c9fef07`'s commit message — "intake's filter is `status=completed`, not
`status=completed AND flagged=false`". The current client has no `flagged`
handling anywhere (`grep -rn flagged lib/` returns nothing in the compliance
path), so a flagged response now counts as satisfying the requirement.

Our own API spec still promises the old semantics:
`lib/scheduling_web/schemas.ex:170` describes the field as "must be completed
(status=completed AND not flagged)". That is stale text on our side and we
will fix it — but we need to know which way to fix it.

**Ask:** confirm whether `flagged` still exists on a response, whether
`status=completed` includes flagged ones, and what you think the right answer
is for a compliance question. Our instinct is that a flagged response should
*not* satisfy a requirement, and that the cleanest place for that rule is your
filter rather than a post-filter here — but it is your data and your notion of
what flagging means, so we would rather ask than assume.

Non-blocking only because the gate is off. It becomes correctness-blocking the
day we turn it on.

## 7. A way to check a reference without learning its name — **non-blocking**

Two halves, both cheap:

- **`complianceRef` on `FormSummary` (`GET /api/v1/forms`).** So an
  administrator working in *your* admin surface, where form names are
  appropriate, can read off the reference to put into our catalog. Today they
  have no way to obtain one. To be explicit: this is for humans and for your
  bridge. Scheduling does not call `/forms` and does not want to.
- **A reference-validity check we can call.** `GET /api/v1/compliance_refs/{ref}`
  → `200` / `404`, or any shape that answers *"is this a live reference"*
  without returning what it refers to.

**What it gets us:** today the catalog screen validates reference *shape*
(`not_a_reference?/1`, `lib/scheduling_web/live/diagnosis_live/index.ex:177`).
Shape is all we can check, so a well-formed reference that is retired or
belongs to another organisation saves cleanly and then fails at a front desk,
months later, as a `503 compliance_unavailable` while a patient waits. A
validity check moves that failure to the moment an administrator types it.

This supersedes an older ask of ours for a form-type catalog endpoint — see
"What we are not asking for".

## 8. A sensitivity flag keyed on the reference — **non-blocking**

```
GET /api/v1/compliance_refs/{ref} → {"sensitive": true}
```

A boolean, or a category enum, on the **reference** — not on the form type,
and without the name. Enough for us to refuse a reference at catalog write
time; not enough for us to learn what it is.

We want to be honest about how much this is worth, because you made the
argument yourselves and you were right: the control that keeps sensitive
encounters out of scheduling altogether is the `BRIDGE_FORM_TYPE_MAP`
exclusion, and reference blinding is defence-in-depth on top of it. A
sensitivity flag is a third layer, and it only covers the one path the other
two miss — an operator typing a reference into the diagnosis catalog by hand,
having obtained it from ask 7's first half. That is a narrow path. It is also
the path where a human is making a judgement call with no information, which
is the kind of place a machine-checkable flag earns its keep.

Lowest priority of the eight. If it is more than a column, drop it.

---

## What we are not asking for

Listed so nobody spends time on them.

- **`?patient_id=` on `/responses`.** You shipped it; we use it (`c9fef07`).
  Thank you — it turned N requests pulling up to 200 rows each into N requests
  returning 0 or 1.
- **The `GET /compliance/status` verdict endpoint.** Withdrawn, and you were
  right to decline it. The policy about which forms an encounter requires is
  ours, so the verdict should be too — and a bare pass/fail cannot be
  explained to someone standing at a desk.
- **A form-type catalog endpoint (`GET /api/v1/form_types`) with names and
  descriptions.** We asked for this in an older internal ticket (`sc-7a7`) and
  we are explicitly withdrawing it. It was written when our catalog field held
  form-type *names*; it now holds `cref_` values, and a catalog of names is
  something scheduling must not hold. Ask 7 is what that ticket should have
  said.
- **Anything else about form content** — definitions, questions, answers,
  notes, results. Not now, not later.
- **Changes to how you mint references.** Random per
  `(organization_id, form_type)` rather than derived is the right call; a
  hashed reference would be recoverable by guessing plausible form names.
- **A push or webhook from intake.** Pull at accept time is the correct shape
  for a gate. This is deliberate, not an omission.
- **Multi-ref queries as a condition of anything.** Ask 4 is an optimisation
  and we will live without it.

## One constraint on our side

**Scheduling carries PII but not health data** — clinical data belongs in the
EMR. Strings like `stroke-consent`, tied to a named patient, are health data,
and in this system they would reach the queue metadata, the append-only
`routing_decisions` rationale, the lifecycle event log, and every outbound
webhook subscription. `test/scheduling/phi_boundary_test.exs` asserts each of
those four paths stays clean.

That is the single constraint shaping all eight asks, and it is why every one
of them is phrased in terms of a reference rather than a form. We would rather
solve this at the interface than ask either team to be careful in perpetuity.
If any shape above is awkward for you, we are glad to work out a different one
that keeps the same property.

## Summary

| # | Ask | Status | What it blocks |
|---|---|---|---|
| 1 | `compliance_ref` filter on `GET /responses` | **blocking** | The gate, entirely. `sc-d6z` |
| 2 | `400` on unsupported query parameters | **blocking** | Enabling the gate without manual per-environment checks |
| 3 | Bridge sends `required_compliance_refs` | **blocking** | `sc-5ed`; without it bridge entries skip the gate |
| 4 | Reference on each returned row | non-blocking | Batching; 1 round-trip per requirement stays |
| 5 | `patientId` on each returned row | non-blocking | Restoring a cross-patient assertion we dropped |
| 6 | Semantics of `flagged` vs `status=completed` | confirm | Correctness once the gate is on |
| 7 | Reference validity check + `complianceRef` on `FormSummary` | non-blocking | Write-time validation; replaces `sc-7a7` ask 1 |
| 8 | `sensitive` flag on a reference | non-blocking | Write-time refusal of a sensitive reference |

Asks 1–3 are what we would like to talk about; 4–8 can be a reply in writing.
