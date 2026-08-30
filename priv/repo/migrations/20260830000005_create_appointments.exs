defmodule Scheduling.Repo.Migrations.CreateAppointments do
  @moduledoc """
  A patient booked into a run of consecutive slots on one office.

  ## `slots.appointment_id` rather than a join table

  A slot holds at most one appointment, and `slots.status` already records
  `:booked`. A join table would put the same fact in two places and let them
  disagree — a slot marked `:booked` with no join row, or the reverse. One
  nullable FK, and the status is derivable from it.

  ## `appointment_capabilities`

  Mirrors `queue_entry_capabilities`. The appointment stores the **resolved
  capabilities**, never the service code that produced them: scheduling holds a
  catalog mapping codes to human-readable service names, so an appointment
  holding the code would let this database resolve patient -> clinical purpose.
  That is what `docs/data-boundary.md` forbids and what Phase 1 removed from
  queue entries.

  ## `external_ref`

  Unique, nullable. A caller retrying a booking must not create a second one;
  the unique index is what makes that guarantee rather than a read-then-write
  that races.
  """
  use Ecto.Migration

  def change do
    create table(:appointments) do
      add :patient_id, references(:patients, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "booked"
      add :binding, :string, null: false
      add :external_ref, :string

      timestamps(type: :utc_datetime)
    end

    create index(:appointments, [:patient_id])
    create index(:appointments, [:status])

    # Partial: several appointments may legitimately have no external ref.
    create unique_index(:appointments, [:external_ref],
             where: "external_ref IS NOT NULL",
             name: :appointments_external_ref_index
           )

    alter table(:slots) do
      # nilify_all, not delete_all: deleting an appointment must never delete
      # the slot it occupied. The slot is generated capacity that outlives any
      # one booking, and losing it would silently shrink a room's calendar.
      add :appointment_id, references(:appointments, on_delete: :nilify_all)
    end

    create index(:slots, [:appointment_id])

    create table(:appointment_capabilities) do
      add :appointment_id, references(:appointments, on_delete: :delete_all), null: false
      add :capability_id, references(:capabilities, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:appointment_capabilities, [:appointment_id])
    create index(:appointment_capabilities, [:capability_id])
    create unique_index(:appointment_capabilities, [:appointment_id, :capability_id])
  end
end
