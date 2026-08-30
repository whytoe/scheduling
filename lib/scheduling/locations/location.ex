defmodule Scheduling.Locations.Location do
  @moduledoc """
  A physical site, projected from ac-core.

  ac-core owns the site list; this is a local cache of the fields scheduling
  needs. `core_location_id` is the identity of record — the local integer id is
  an implementation detail and should not travel.

  ## A location is not an office

  An ac-core location is a **site**: it has an address and a timezone. A
  scheduling `Office` is a **room or service point**: it has an intake capacity
  and a set of capabilities. Several offices sit in one site, so the
  relationship is one-to-many rather than the two being the same thing.

  That distinction is easy to lose because both are "places". Getting it wrong
  would either collapse every room at a site into one bookable resource, or
  invent a site per room.

  ## Timezone

  A location carries ac-core's timezone, but `Office.timezone` is what slot
  generation actually reads — generation is per office, and an office is what
  a rule attaches to. A location's timezone is the sensible default to adopt
  when linking a room to a site, not an override applied behind the operator's
  back.

  ## Fields are projected, not merged

  Only the fields named here are stored. `Scheduling.Core.Client` already
  drops everything else at the boundary, and this schema deliberately does not
  grow to match whatever ac-core adds — see `docs/data-boundary.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Offices.Office

  @type t :: %__MODULE__{}

  schema "locations" do
    field :core_location_id, :string
    field :core_practice_id, :string
    field :name, :string
    field :address, :string
    field :timezone, :string
    field :active, :boolean, default: true
    field :synced_at, :utc_datetime

    has_many :offices, Office

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(location, attrs) do
    location
    |> cast(attrs, [
      :core_location_id,
      :core_practice_id,
      :name,
      :address,
      :timezone,
      :active,
      :synced_at
    ])
    |> validate_required([:core_location_id, :name])
    |> validate_length(:core_location_id, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_timezone()
    |> unique_constraint(:core_location_id)
  end

  # ac-core is not obliged to send a timezone this VM knows about, and an
  # unusable one is worse than none: an office adopting it would fail at
  # generation rather than here. Drop it and keep the rest of the record.
  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      tz ->
        case DateTime.now(tz) do
          {:ok, _dt} -> changeset
          {:error, _reason} -> put_change(changeset, :timezone, nil)
        end
    end
  end
end
