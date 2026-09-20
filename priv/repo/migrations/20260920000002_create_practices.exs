defmodule Scheduling.Repo.Migrations.CreatePractices do
  @moduledoc """
  Projects ac-core's practices, so two sites with the same name can be told
  apart.

  The deployment currently holds five locations, and **three of them are called
  "Main Office"** — one per practice, which is normal and follows directly from
  being bound to three practices. Two of those three have no address either.
  So an operator choosing between rooms at different sites can see the same
  name, no practice, and nothing else.

  `locations.core_practice_id` was already stored; nothing had the name to go
  with it.

  Keyed on `core_practice_id` rather than a local serial FK on locations, so
  the association resolves by ac-core's own identifier. A location whose
  practice has not been synced yet simply has no practice rather than a
  dangling reference, which keeps the two syncs independent.
  """
  use Ecto.Migration

  def change do
    create table(:practices) do
      add :core_practice_id, :string, null: false
      add :name, :string
      add :slug, :string
      add :core_organization_id, :string
      add :active, :boolean, default: true, null: false
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:practices, [:core_practice_id])

    # No index needed on locations.core_practice_id — 20260830000004 already
    # created one when the column was added.
  end
end
