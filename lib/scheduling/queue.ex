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
  alias Scheduling.Catalog
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

  Optional patient-id filters (each AND-composable with the others):

    * `:patient_id`         (int)   — scheduling-side patient id (FK direct)
    * `:intake_patient_id`  (uuid)  — joins patients, filters server-side
    * `:external_id`        (str)   — joins patients, filters server-side
    * `:client_id`          (uuid)  — joins patients, filters server-side

  Used by integration services (e.g. the intake-scheduling-bridge) to ask
  "does this patient already have a waiting entry?" before creating a new
  one — avoids duplicates on outbox replay.
  """
  def list_waiting_entries(filters \\ %{}) do
    QueueEntry
    |> where([e], e.status == :waiting)
    |> order_by([e], desc: e.priority, asc: e.inserted_at, asc: e.id)
    |> apply_patient_id_filters(filters)
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
  office and required capabilities preloaded for display. Supports the same
  patient-id filters as `list_waiting_entries/1`.
  """
  def list_active_entries(filters \\ %{}) do
    active = QueueEntry.active_statuses()

    QueueEntry
    |> where([e], e.status in ^active)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> apply_patient_id_filters(filters)
    |> Repo.all()
    |> Repo.preload([:patient, :assigned_office, :required_capabilities])
  end

  defp apply_patient_id_filters(query, filters) do
    filters = Map.new(filters)

    query
    |> filter_by_patient_id(Map.get(filters, :patient_id))
    |> filter_by_patient_field(:intake_patient_id, Map.get(filters, :intake_patient_id))
    |> filter_by_patient_field(:external_id, Map.get(filters, :external_id))
    |> filter_by_patient_field(:client_id, Map.get(filters, :client_id))
  end

  defp filter_by_patient_id(query, nil), do: query

  defp filter_by_patient_id(query, id) when is_integer(id),
    do: where(query, [e], e.patient_id == ^id)

  defp filter_by_patient_field(query, _field, nil), do: query

  defp filter_by_patient_field(query, field, value) when is_binary(value) do
    from e in query,
      join: p in assoc(e, :patient),
      where: field(p, ^field) == ^value
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
  `priority` and `compliance_ref`, and either `required_capability_ids` or
  `diagnosis_id` to set the patient's required capabilities. Defaults to
  `status: :waiting`.

  `diagnosis_id` is a **transient input**, not a stored field: it is expanded
  to that diagnosis's default capabilities and then discarded. Scheduling keeps
  the equipment requirement, never the clinical reason for it — see
  `docs/data-boundary.md`. `required_capability_ids` wins when both are given.

  Returns `{:ok, entry}` with `:patient` and `:required_capabilities`
  preloaded, or `{:error, changeset}`.
  """
  @spec create_entry(map(), keyword()) :: {:ok, QueueEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_entry(attrs, opts \\ []) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "waiting")
      |> Map.put_new("priority", 0)

    changeset =
      %QueueEntry{required_capabilities: []}
      |> QueueEntry.changeset(attrs)
      |> put_required_capabilities(attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:entry, changeset)
    |> Ecto.Multi.run(:event, fn _repo, %{entry: entry} ->
      Audit.record_event(%{
        type: "queue_entry.created",
        visit_id: entry.visit_id,
        queue_entry_id: entry.id,
        patient_id: entry.patient_id,
        actor_type: Keyword.get(opts, :actor_type),
        actor_id: Keyword.get(opts, :actor_id),
        # Priority only. This payload is serialised verbatim into every
        # outbound webhook, so nothing clinical may enter it.
        payload: %{priority: entry.priority}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: entry}} ->
        {:ok, Repo.preload(entry, [:patient, :required_capabilities, :assigned_office])}

      {:error, _, changeset, _} ->
        {:error, changeset}
    end
  end

  # Precedence: an explicit capability list, then a service code, then a
  # diagnosis id. Each of the latter two is expanded to the catalog entry's
  # default capabilities and goes no further — the entry records the equipment
  # need, never the service that implied it.
  #
  # `service_code` is the form external callers should use. It is the catalog's
  # stable contract key rather than a row id, and it can be opaque
  # (`svc_7a2f`), so check-in can name a service without either side putting a
  # clinical label on the wire.
  defp put_required_capabilities(changeset, attrs) do
    cond do
      Map.has_key?(attrs, "required_capability_ids") ->
        ids = Map.get(attrs, "required_capability_ids")
        Ecto.Changeset.put_assoc(changeset, :required_capabilities, load_capabilities(ids))

      present?(Map.get(attrs, "service_code")) ->
        expand_template(
          changeset,
          :service_code,
          Catalog.fetch_diagnosis_by_code(Map.get(attrs, "service_code")),
          attrs
        )

      present?(Map.get(attrs, "diagnosis_id")) ->
        expand_template(
          changeset,
          :diagnosis_id,
          Catalog.fetch_diagnosis(Map.get(attrs, "diagnosis_id")),
          attrs
        )

      true ->
        changeset
    end
  end

  # A template supplies both halves of an encounter's requirements: the
  # capabilities that decide which room can serve it, and the compliance
  # references that decide whether it may be served at all. Resolving both here
  # is what lets the gate work without the entry holding a diagnosis — see the
  # migration that added `required_compliance_refs`.
  #
  # An explicit `required_compliance_refs` in the request wins, so a caller
  # that knows the encounter's requirements (the intake bridge does) is not
  # overridden by the catalog default.
  defp expand_template(changeset, _field, {:ok, template}, attrs) do
    changeset = Ecto.Changeset.put_assoc(changeset, :required_capabilities, template.capabilities)

    if Map.has_key?(attrs, "required_compliance_refs") do
      changeset
    else
      Ecto.Changeset.put_change(
        changeset,
        :required_compliance_refs,
        template.required_compliance_refs || []
      )
    end
  end

  defp expand_template(changeset, field, :error, _attrs),
    do: Ecto.Changeset.add_error(changeset, field, "does not exist")

  defp present?(value), do: (is_binary(value) and value != "") or is_integer(value)

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
    # Compliance.verify/1 needs the entry's required_compliance_refs and the
    # patient's intake_patient_id; get_entry!/1 preloads the patient already.
    # It no longer needs a diagnosis — the references were resolved when the
    # entry was created.
    case Compliance.verify(entry) do
      :ok -> do_accept(entry, opts)
      :not_configured -> do_accept(entry, opts)
      {:blocked, unmet} -> record_compliance_block(entry, unmet, opts)
      {:error, reason} -> record_compliance_unavailable(entry, reason, opts)
    end
  end

  defp do_accept(entry, opts) do
    result =
      Matching.match_queue_entry(entry, current_loads(),
        location_ids: Keyword.get(opts, :location_ids)
      )

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

  # The rationale is written to an append-only audit row that also fans out to
  # every webhook subscriber, so it names the reference, never the form types
  # behind it. The "Compliance check failed" prefix is load-bearing —
  # SchedulingWeb.RoutingDecisionLive.Index derives the outcome filter from it.
  defp record_compliance_block(entry, unmet, opts) do
    rationale =
      case unmet do
        [] -> "Compliance check failed"
        refs -> "Compliance check failed for reference " <> Enum.join(refs, ", ")
      end

    result = %Result{
      required: entry.required_capabilities,
      eligible: [],
      chosen: nil,
      rationale: rationale
    }

    Audit.record_decision(entry, result, opts)
    {:compliance_failed, unmet}
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
  @spec complete(QueueEntry.t(), keyword()) ::
          {:ok, QueueEntry.t()} | {:error, Ecto.Changeset.t()}
  def complete(%QueueEntry{} = entry, opts \\ []) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:entry, QueueEntry.completion_changeset(entry))
    |> Ecto.Multi.run(:event, fn _repo, %{entry: completed} ->
      Audit.record_event(%{
        type: "queue_entry.completed",
        visit_id: completed.visit_id,
        queue_entry_id: completed.id,
        patient_id: completed.patient_id,
        actor_type: Keyword.get(opts, :actor_type),
        actor_id: Keyword.get(opts, :actor_id),
        payload: %{assigned_office_id: completed.assigned_office_id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: completed}} ->
        broadcast_board_change({:completed, completed.id})
        {:ok, Repo.preload(completed, [:patient, :assigned_office])}

      {:error, _, changeset, _} ->
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
