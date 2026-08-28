defmodule Scheduling.Repo.Migrations.PhiMinimisationQueueEntries do
  @moduledoc """
  Scheduling carries PII but not health data — clinical data belongs in the EMR.

  `queue_entries.diagnosis_id` linked a named patient to a diagnosis, which is
  health data by any reading. It also contributed nothing to routing:
  `Scheduling.Matching.match_queue_entry/2` reads only the entry's
  `required_capabilities`, and nothing ever copied a diagnosis's default
  capabilities onto an entry. The column's only real consumers were the
  compliance gate (which read `required_form_types` through it) and three
  display labels.

  `compliance_ref` replaces it for the gate's purposes: an opaque token supplied
  by whoever creates the entry, which the intake-form system resolves to "which
  forms does this person need". Scheduling passes it through and never learns
  the form-type names.

  Diagnoses themselves stay — as an unlinked routing-template catalog. They
  define rules, not patient facts.
  """
  use Ecto.Migration

  def up do
    alter table(:queue_entries) do
      remove :diagnosis_id
      add :compliance_ref, :string
    end
  end

  def down do
    alter table(:queue_entries) do
      remove :compliance_ref
      add :diagnosis_id, references(:diagnoses, on_delete: :nilify_all)
    end

    create index(:queue_entries, [:diagnosis_id])
  end
end
