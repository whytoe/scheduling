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
  alias Scheduling.Catalog.Capability
  alias Scheduling.Compliance
  alias Scheduling.Handoffs
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
  Lists the entries currently occupying office capacity (statuses in
  `QueueEntry.active_statuses/0`), oldest first, with the patient, assigned
  office and required capabilities preloaded for display.
  """
  def list_active_entries do
    active = QueueEntry.active_statuses()

    QueueEntry
    |> where([e], e.status in ^active)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> Repo.all()
    |> Repo.preload([:patient, :assigned_office, :required_capabilities])
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
  Creates a new queue entry. Accepts `patient_id` (required), optional
  `diagnosis_id` and `priority`, and `required_capability_ids` to set the
  patient's required capabilities. Defaults to `status: :waiting`.

  Returns `{:ok, entry}` with `:patient` and `:required_capabilities`
  preloaded, or `{:error, changeset}`.
  """
  @spec create_entry(map()) :: {:ok, QueueEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_entry(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "waiting")
      |> Map.put_new("priority", 0)

    %QueueEntry{required_capabilities: []}
    |> QueueEntry.changeset(attrs)
    |> put_required_capabilities(attrs)
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, Repo.preload(entry, [:patient, :required_capabilities, :assigned_office])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp put_required_capabilities(changeset, attrs) do
    case Map.fetch(attrs, "required_capability_ids") do
      {:ok, ids} ->
        caps = load_capabilities(ids)
        Ecto.Changeset.put_assoc(changeset, :required_capabilities, caps)

      :error ->
        changeset
    end
  end

  defp load_capabilities(nil), do: []

  defp load_capabilities(ids) do
    parsed =
      ids
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&to_id/1)

    case parsed do
      [] -> []
      ids -> Capability |> where([c], c.id in ^ids) |> Repo.all()
    end
  end

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Accepts a waiting patient from the queue: computes current office loads, runs
  the best-fit matcher over the patient's required capabilities, and assigns
  the patient to the chosen office.

  Every matcher run is recorded to the routing-decision audit log (both the
  assigned and no-eligible-office outcomes). On a successful assignment an
  incoming-patient handoff is created and broadcast to the target office's
  clinical staff (see `Scheduling.Handoffs`). `opts` may carry `:accepted_by`.

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
          | {:compliance_failed, [String.t()]}
          | {:compliance_unavailable, term()}
          | {:error, Ecto.Changeset.t()}
  def accept(%QueueEntry{} = entry, opts \\ []) do
    # Compliance.verify needs the diagnosis (for required_form_types) and the
    # patient (for intake_patient_id). get_entry!/1 preloads patient already;
    # we add diagnosis here so the gate has what it needs.
    entry = Repo.preload(entry, [:diagnosis])

    case Compliance.verify(entry) do
      :ok -> do_accept(entry, opts)
      :not_configured -> do_accept(entry, opts)
      {:missing, missing_types} -> record_compliance_block(entry, missing_types, opts)
      {:error, reason} -> record_compliance_unavailable(entry, reason, opts)
    end
  end

  defp do_accept(entry, opts) do
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
            Handoffs.create_handoff(assigned, office)
            broadcast_board_change({:accepted, assigned.id})
            {:ok, Repo.preload(assigned, [:patient, :assigned_office]), result}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp record_compliance_block(entry, missing_types, opts) do
    rationale =
      "Compliance check failed: missing required form types [" <>
        Enum.join(missing_types, ", ") <> "]"

    result = %Result{
      required: entry.required_capabilities,
      eligible: [],
      chosen: nil,
      rationale: rationale
    }

    Audit.record_decision(entry, result, opts)
    {:compliance_failed, missing_types}
  end

  defp record_compliance_unavailable(entry, reason, opts) do
    rationale = "Compliance check unavailable: " <> inspect(reason)

    result = %Result{
      required: entry.required_capabilities,
      eligible: [],
      chosen: nil,
      rationale: rationale
    }

    Audit.record_decision(entry, result, opts)
    {:compliance_unavailable, reason}
  end

  @doc """
  Completes service for an in-progress entry: transitions it to `:completed`
  and thereby frees the assigned office's intake capacity (a completed entry no
  longer counts toward load). Broadcasts the capacity change on the board topic
  so every connected board and the matcher's next run reflect the freed slot.

  Returns `{:ok, entry}` with `:patient` and `:assigned_office` preloaded, or
  `{:error, changeset}` if the entry was not in an active status.
  """
  @spec complete(QueueEntry.t()) :: {:ok, QueueEntry.t()} | {:error, Ecto.Changeset.t()}
  def complete(%QueueEntry{} = entry) do
    entry
    |> QueueEntry.completion_changeset()
    |> Repo.update()
    |> case do
      {:ok, completed} ->
        broadcast_board_change({:completed, completed.id})
        {:ok, Repo.preload(completed, [:patient, :assigned_office])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Re-queues an in-progress entry: returns the patient to the `:waiting` queue
  for an additional service instead of fully exiting. Clears the office
  assignment (freeing its capacity) and optionally replaces the required
  capabilities via `opts[:required_capabilities]` (a list of `Capability`
  structs) to capture the new service's requirements. Broadcasts the capacity
  change on the board topic.

  Returns `{:ok, entry}` with `:patient` and `:required_capabilities`
  preloaded, or `{:error, changeset}` if the entry was not in an active status.
  """
  @spec requeue(QueueEntry.t(), keyword()) ::
          {:ok, QueueEntry.t()} | {:error, Ecto.Changeset.t()}
  def requeue(%QueueEntry{} = entry, opts \\ []) do
    entry
    |> Repo.preload(:required_capabilities)
    |> QueueEntry.requeue_changeset(opts)
    |> Repo.update()
    |> case do
      {:ok, requeued} ->
        broadcast_board_change({:requeued, requeued.id})
        {:ok, Repo.preload(requeued, [:patient, :required_capabilities])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
