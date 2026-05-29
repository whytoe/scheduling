defmodule Scheduling.Queue do
  @moduledoc """
  The intake queue: patients waiting to be accepted, and the accept-from-queue
  flow that assigns a waiting patient to the best-fit eligible office.

  Office load is derived, not stored: an office's current load is the number of
  queue entries assigned to it that still occupy capacity (see
  `QueueEntry.active_statuses/0`). `current_loads/0` produces the load map the
  matcher consumes; `accept/1` ties matching and assignment together.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Audit
  alias Scheduling.Matching
  alias Scheduling.Matching.Result
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  @board_topic "scheduling:board"

  @doc "The PubSub topic carrying live board changes (queue + capacity)."
  def board_topic, do: @board_topic

  @doc "Subscribes the caller to live board changes. Call from a LiveView mount."
  def subscribe_board do
    Phoenix.PubSub.subscribe(Scheduling.PubSub, @board_topic)
  end

  defp broadcast_board_change(event) do
    Phoenix.PubSub.broadcast(Scheduling.PubSub, @board_topic, {:board_changed, event})
  end

  @doc """
  Lists waiting queue entries, highest priority first then oldest, with the
  patient and required capabilities preloaded for display.
  """
  def list_waiting_entries do
    QueueEntry
    |> where([e], e.status == :waiting)
    |> order_by([e], desc: e.priority, asc: e.inserted_at, asc: e.id)
    |> Repo.all()
    |> Repo.preload([:patient, :required_capabilities])
  end

  @doc "Fetches a queue entry by id with patient and required capabilities preloaded."
  def get_entry!(id) do
    QueueEntry
    |> Repo.get!(id)
    |> Repo.preload([:patient, :required_capabilities, :assigned_office])
  end

  @doc """
  Current per-office load as a `%{office_id => count}` map, counting only
  entries whose status occupies capacity. Offices with no active assignments
  are absent from the map (the matcher treats them as zero load).
  """
  @spec current_loads() :: %{optional(integer()) => non_neg_integer()}
  def current_loads do
    active = QueueEntry.active_statuses()

    QueueEntry
    |> where([e], e.status in ^active and not is_nil(e.assigned_office_id))
    |> group_by([e], e.assigned_office_id)
    |> select([e], {e.assigned_office_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Accepts a waiting patient from the queue: computes current office loads, runs
  the best-fit matcher over the patient's required capabilities, and assigns
  the patient to the chosen office.

  Every matcher run is recorded to the routing-decision audit log (both the
  assigned and no-eligible-office outcomes). `opts` may carry `:accepted_by`.

  Returns:

    * `{:ok, entry, result}` — assigned; `entry` reloaded as `:assigned` with
      `assigned_office` preloaded, `result` carries the rationale.
    * `{:no_eligible_office, result}` — no office both provides the required
      capabilities and has free capacity; the entry stays `:waiting`.
    * `{:error, changeset}` — the assignment write failed (e.g. the entry was
      no longer waiting).
  """
  @spec accept(QueueEntry.t(), keyword()) ::
          {:ok, QueueEntry.t(), Result.t()}
          | {:no_eligible_office, Result.t()}
          | {:error, Ecto.Changeset.t()}
  def accept(%QueueEntry{} = entry, opts \\ []) do
    result = Matching.match_queue_entry(entry, current_loads())

    case Result.chosen_office(result) do
      nil ->
        Audit.record_decision(entry, result, opts)
        {:no_eligible_office, result}

      office ->
        entry
        |> QueueEntry.assignment_changeset(office)
        |> Repo.update()
        |> case do
          {:ok, assigned} ->
            Audit.record_decision(entry, result, opts)
            broadcast_board_change({:accepted, assigned.id})
            {:ok, Repo.preload(assigned, [:patient, :assigned_office]), result}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end
end
