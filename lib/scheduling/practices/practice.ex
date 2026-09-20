defmodule Scheduling.Practices.Practice do
  @moduledoc """
  A practice, projected from ac-core. Its only job here is to give a location a
  name an operator recognises.

  ac-core owns everything about it; nothing in scheduling edits one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "practices" do
    field :core_practice_id, :string
    field :name, :string
    field :slug, :string
    field :core_organization_id, :string
    field :active, :boolean, default: true
    field :synced_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(practice, attrs) do
    practice
    |> cast(attrs, [:core_practice_id, :name, :slug, :core_organization_id, :active, :synced_at])
    |> validate_required([:core_practice_id])
    |> unique_constraint(:core_practice_id)
  end
end
