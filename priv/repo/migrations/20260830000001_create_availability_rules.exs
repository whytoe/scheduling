defmodule Scheduling.Repo.Migrations.CreateAvailabilityRules do
  @moduledoc """
  A recurring statement of when an office is bookable: "Room 3, Mondays,
  09:00–17:00, 20-minute slots".

  Times are the office's **local wall time**, stored as `:time` with no zone.
  That is deliberate — a rule means "nine in the morning where the room is",
  and it has to keep meaning that across a DST transition. Resolving to an
  instant happens at generation, through the office's timezone. Storing a
  UTC offset here would freeze it at whatever it was the day the rule was
  written and drift by an hour twice a year.

  `effective_from` / `effective_until` bound the rule's life, so a schedule
  change is a new rule rather than an edit that silently rewrites history.
  """
  use Ecto.Migration

  def change do
    create table(:availability_rules) do
      add :office_id, references(:offices, on_delete: :delete_all), null: false
      add :day_of_week, :integer, null: false
      add :starts_at, :time, null: false
      add :ends_at, :time, null: false
      add :slot_minutes, :integer, null: false
      add :effective_from, :date, null: false
      add :effective_until, :date
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:availability_rules, [:office_id])
    create index(:availability_rules, [:office_id, :day_of_week, :active])
  end
end
