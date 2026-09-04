defmodule Scheduling.Repo.Migrations.ComplianceRefs do
  @moduledoc """
  Moves the compliance gate from a verdict endpoint to a set of opaque form
  references, per intake's counter-proposal — see `docs/intake-compliance-reply.md`.

  Two changes, both about where the requirement set lives.

  `queue_entries.required_compliance_refs` holds the references an entry must
  satisfy, resolved at creation the way `required_capabilities` already is.
  Scheduling needs this because it computes the verdict now: intake answers
  "does this patient have a completed response for this reference", and only
  scheduling knows which references the encounter demanded. It cannot be
  derived at accept time — `queue_entries.diagnosis_id` was dropped
  deliberately so a named patient is not linked to a diagnosis, and it is not
  coming back.

  `diagnoses.required_form_types` becomes `required_compliance_refs`. The
  column already held opaque-to-us strings; after the config migration they
  stop being words. Renaming rather than leaving it is the point: a field
  called "form types" invites someone to type `stroke-consent` into it, and
  that string bound to a patient is exactly the health data this system must
  not carry. After this migration no field in the schema is named for clinical
  content.

  The values themselves are a **config migration, not a data migration** —
  intake mints the references per `(organization_id, form_type)` and a clinic
  admin reads them from `GET /api/v1/forms`. This migration deliberately does
  not translate existing names: there is no mapping to translate them with, and
  inventing one would fabricate requirements.

  ## What happens to the old values

  Existing rows keep their strings. A leftover `"stroke-consent"` is not a
  reference intake recognises, so it comes back `400` — which maps to
  `:compliance_unavailable`, not `:compliance_failed`. The distinction is the
  point: the front desk is told the check could not run, not that the patient
  is missing paperwork.

  That is deliberately loud and deliberately fail-closed. Clearing the column
  instead would read as "no requirements" and let every entry through, which is
  the silent-skip failure this whole exchange was about.

  It is also not felt until someone sets `INTAKE_API_KEY`: with the gate
  unconfigured `verify/1` returns `:not_configured` and accepts. So the safe
  order is — migrate the config values, *then* enable the gate.
  """
  use Ecto.Migration

  def up do
    alter table(:queue_entries) do
      add :required_compliance_refs, {:array, :string}, default: [], null: false
    end

    rename table(:diagnoses), :required_form_types, to: :required_compliance_refs
  end

  def down do
    rename table(:diagnoses), :required_compliance_refs, to: :required_form_types

    alter table(:queue_entries) do
      remove :required_compliance_refs
    end
  end
end
