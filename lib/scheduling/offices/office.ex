defmodule Scheduling.Offices.Office do
  @moduledoc """
  A clinic location/room with an intake capacity (how many patients it can
  serve concurrently) and a set of capabilities it can provide.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability

  schema "offices" do
    field :name, :string
    field :intake_capacity, :integer, default: 0
    field :timezone, :string, default: "Etc/UTC"

    # The physical site this room sits in. Nullable: offices predate locations,
    # and a room not yet tied to a site still routes patients perfectly well.
    belongs_to :location, Scheduling.Locations.Location

    many_to_many :capabilities, Capability,
      join_through: Scheduling.Offices.OfficeCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(office, attrs) do
    office
    |> cast(attrs, [:name, :intake_capacity, :timezone, :location_id])
    |> validate_required([:name, :intake_capacity, :timezone])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:intake_capacity, greater_than_or_equal_to: 0)
    |> validate_timezone()
    |> assoc_constraint(:location)
    |> unique_constraint(:name)
  end

  # Availability rules are written in the office's local time and slots are
  # stored in UTC, so a bad timezone silently shifts a whole calendar rather
  # than failing loudly. Check it at write time.
  #
  # Via `DateTime.now/1` rather than a library-specific identifier list: that
  # asks whichever time zone database is actually configured, so the check can
  # never pass here and then fail at conversion time.
  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, tz ->
      case DateTime.now(tz) do
        {:ok, _dt} -> []
        {:error, _reason} -> [timezone: "is not a known IANA time zone"]
      end
    end)
  end
end
