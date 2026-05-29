defmodule Scheduling.Handoffs do
  @moduledoc """
  Incoming-patient handoffs: the front-desk → clinical bridge. When the accept
  flow assigns a patient to an office, a durable handoff record notifies that
  office's clinical staff that a patient is incoming, carrying the patient's
  required capabilities, so nothing is dropped or only verbally relayed.

  Each handoff is broadcast in real time on two topics: a per-office topic
  (`office_topic/1`) scoped to the target office's clinical staff, and a
  board-wide topic (`handoffs_topic/0`) the shared board watches. Handoffs
  persist with a `:pending`/`:acknowledged` status so an incoming patient
  survives a reload and clears only when staff acknowledge receipt — the live
  broadcast is a notification, not the source of truth.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Handoffs.Handoff
  alias Scheduling.Offices.Office
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  @handoffs_topic "scheduling:handoffs"

  @doc "The board-wide topic carrying every handoff event."
  def handoffs_topic, do: @handoffs_topic

  @doc "The topic carrying handoff events scoped to a single target office."
  def office_topic(office_id), do: "scheduling:office:#{office_id}:handoffs"

  @doc "Subscribes the caller to every handoff event (for the shared board)."
  def subscribe_handoffs do
    Phoenix.PubSub.subscribe(Scheduling.PubSub, @handoffs_topic)
  end

  @doc "Subscribes the caller to handoffs for one office (for an office view)."
  def subscribe_office(office_id) do
    Phoenix.PubSub.subscribe(Scheduling.PubSub, office_topic(office_id))
  end

  defp broadcast(%Handoff{} = handoff, event) do
    message = {event, handoff}
    Phoenix.PubSub.broadcast(Scheduling.PubSub, office_topic(handoff.office_id), message)
    Phoenix.PubSub.broadcast(Scheduling.PubSub, @handoffs_topic, message)
    handoff
  end

  @doc """
  Records and broadcasts an incoming-patient handoff for a freshly assigned
  entry. Snapshots the patient name, office name, and required-capability names
  so the handoff stays readable independent of the live rows. Broadcasts
  `{:handoff_created, handoff}` on the target office topic and the board topic.

  Returns `{:ok, handoff}` or `{:error, changeset}`.
  """
  @spec create_handoff(QueueEntry.t(), Office.t()) ::
          {:ok, Handoff.t()} | {:error, Ecto.Changeset.t()}
  def create_handoff(%QueueEntry{} = entry, %Office{} = office) do
    entry = Repo.preload(entry, [:patient, :required_capabilities])

    %Handoff{}
    |> Handoff.changeset(%{
      office_id: office.id,
      patient_id: entry.patient_id,
      queue_entry_id: entry.id,
      status: :pending,
      patient_name: patient_name(entry),
      office_name: office.name,
      required_capabilities: capability_names(entry.required_capabilities)
    })
    |> Repo.insert()
    |> case do
      {:ok, handoff} -> {:ok, broadcast(handoff, :handoff_created)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Acknowledges receipt of an incoming patient, clearing the handoff from the
  pending list. Broadcasts `{:handoff_acknowledged, handoff}` on both topics.
  `opts` may carry `:acknowledged_by`.

  Returns `{:ok, handoff}` or `{:error, changeset}` if the handoff was not
  pending.
  """
  @spec acknowledge(Handoff.t(), keyword()) ::
          {:ok, Handoff.t()} | {:error, Ecto.Changeset.t()}
  def acknowledge(%Handoff{} = handoff, opts \\ []) do
    handoff
    |> Handoff.acknowledge_changeset(opts)
    |> Repo.update()
    |> case do
      {:ok, acknowledged} -> {:ok, broadcast(acknowledged, :handoff_acknowledged)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Lists every pending (unacknowledged) handoff, oldest first."
  @spec list_pending() :: [Handoff.t()]
  def list_pending do
    Handoff
    |> where([h], h.status == :pending)
    |> order_by([h], asc: h.inserted_at, asc: h.id)
    |> Repo.all()
  end

  @doc "Lists pending handoffs incoming to one office, oldest first."
  @spec list_pending_for_office(integer()) :: [Handoff.t()]
  def list_pending_for_office(office_id) do
    Handoff
    |> where([h], h.status == :pending and h.office_id == ^office_id)
    |> order_by([h], asc: h.inserted_at, asc: h.id)
    |> Repo.all()
  end

  @doc "Fetches a handoff by id. Raises if missing."
  def get_handoff!(id), do: Repo.get!(Handoff, id)

  defp patient_name(%QueueEntry{patient: %{name: name}}) when is_binary(name), do: name
  defp patient_name(_entry), do: nil

  defp capability_names(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp capability_names(_), do: []
end
