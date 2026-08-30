defmodule Scheduling.Repo.Migrations.CreateSlots do
  @moduledoc """
  Concrete bookable instants, expanded from `availability_rules`.

  Rules describe a repeating weekly pattern in an office's local wall time;
  slots are the resolved UTC instants that pattern produces on real dates.

  ## The unique index is load-bearing

  `(office_id, starts_at)` is unique because an office cannot have two slots
  beginning at the same instant. That single constraint does three jobs:

    * it makes regeneration safe to run repeatedly — a second pass conflicts
      with what is already there and leaves it alone,
    * it is therefore what stops regeneration from destroying a booked slot,
      because the existing row is never touched, and
    * it turns two overlapping rules for one office from a silently
      double-booked room into a detectable conflict.

  ## Why `availability_rule_id` nullifies rather than cascades

  A slot outlives the rule that produced it. Deleting a rule — which
  `Scheduling.Booking` documents as being for one created in error, not for a
  schedule change — must not take a booked slot with it. Nullifying leaves the
  slot standing with its provenance gone, which is the honest encoding of
  "orphaned", and is exactly what the availability-rule docs warn deletion
  does.
  """
  use Ecto.Migration

  def change do
    create table(:slots) do
      add :office_id, references(:offices, on_delete: :delete_all), null: false
      add :availability_rule_id, references(:availability_rules, on_delete: :nilify_all)
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:slots, [:office_id, :starts_at])

    # Availability search walks a time window across every office, and
    # regeneration asks "what already exists in this range?" — both are range
    # scans on starts_at narrowed by status.
    create index(:slots, [:starts_at, :status])
    create index(:slots, [:availability_rule_id])
  end
end
