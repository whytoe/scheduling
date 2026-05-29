defmodule Scheduling.Queue.QueueEntryCapability do
  @moduledoc """
  Join table holding the explicit set of `Capability` entries required by a
  `QueueEntry`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability
  alias Scheduling.Queue.QueueEntry

  schema "queue_entry_capabilities" do
    belongs_to :queue_entry, QueueEntry
    belongs_to :capability, Capability

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(queue_entry_capability, attrs) do
    queue_entry_capability
    |> cast(attrs, [:queue_entry_id, :capability_id])
    |> validate_required([:queue_entry_id, :capability_id])
    |> assoc_constraint(:queue_entry)
    |> assoc_constraint(:capability)
    |> unique_constraint([:queue_entry_id, :capability_id])
  end
end
