defmodule Scheduling.Repo.Migrations.CreateLocations do
  @moduledoc """
  Physical sites, projected from ac-core.

  ac-core owns the site list (`GET /v1/locations`); this is a local cache of
  the fields scheduling needs, so the board keeps its labels when the registry
  is briefly unreachable and every render is not a round trip.

  **An office is not a location.** An ac-core location is a site — it has an
  address and a timezone. A scheduling office is a room or service point with
  an intake capacity and a set of capabilities. Several offices sit in one
  site, so `offices.location_id` is a nullable belongs-to rather than the two
  being the same row.

  Nullable because offices existed before locations did, and a room that has
  not been tied to a site yet still routes patients perfectly well.
  """
  use Ecto.Migration

  def change do
    create table(:locations) do
      # ac-core ids are opaque strings, not integers or uuids.
      add :core_location_id, :string, null: false
      add :core_practice_id, :string
      add :name, :string, null: false
      add :address, :string
      add :timezone, :string
      add :active, :boolean, null: false, default: true
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:locations, [:core_location_id])
    create index(:locations, [:core_practice_id])

    alter table(:offices) do
      add :location_id, references(:locations, on_delete: :nilify_all)
    end

    # Not unique: many offices per site.
    create index(:offices, [:location_id])
  end
end
