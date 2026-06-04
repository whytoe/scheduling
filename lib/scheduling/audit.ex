defmodule Scheduling.Audit do
  @moduledoc """
  Two audit logs, both write-once / read-only afterwards:

  * `RoutingDecision` — one row per matcher run during the accept flow.
    Specialized columns (chosen_office_id FK, eligible_offices array,
    rationale) for matcher-specific queries.
  * `VisitEvent` — lifecycle events (sign-in, completion, handoff
    acknowledgement, future cancel/no_show/disposition). Polymorphic
    `payload` jsonb for the per-type extras. Sibling to RoutingDecision.

  Together they form the visit timeline; clients can union them or query
  each separately.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Audit.{RoutingDecision, VisitEvent}
  alias Scheduling.Matching.{Candidate, Result}
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  @doc """
  Persists one `RoutingDecision` for a completed matcher run on the given queue
  entry. `result` is the matcher's `Result`; `opts` may carry `:accepted_by`.

  Returns `{:ok, decision}` or `{:error, changeset}`.
  """
  @spec record_decision(QueueEntry.t(), Result.t(), keyword()) ::
          {:ok, RoutingDecision.t()} | {:error, Ecto.Changeset.t()}
  def record_decision(%QueueEntry{} = entry, %Result{} = result, opts \\ []) do
    chosen_office = Result.chosen_office(result)

    %RoutingDecision{}
    |> RoutingDecision.changeset(%{
      patient_id: entry.patient_id,
      queue_entry_id: entry.id,
      chosen_office_id: chosen_office && chosen_office.id,
      patient_name: patient_name(entry),
      chosen_office_name: chosen_office && chosen_office.name,
      required_capabilities: capability_names(result.required),
      eligible_offices: eligible_office_names(result.eligible),
      rationale: result.rationale,
      accepted_by: Keyword.get(opts, :accepted_by)
    })
    |> Repo.insert()
  end

  @doc """
  Lists routing decisions, most recent first, with associations preloaded.
  Optional filter `:since` (a `%DateTime{}`) returns decisions with
  `inserted_at >= since` — useful for incremental polling.
  """
  @spec list_decisions(map() | keyword()) :: [RoutingDecision.t()]
  def list_decisions(filters \\ %{}) do
    filters
    |> decisions_query()
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> Repo.all()
    |> Repo.preload([:patient, :chosen_office, :queue_entry])
  end

  @doc "Composable routing-decisions query — for paginated reads."
  @spec decisions_query(map() | keyword()) :: Ecto.Queryable.t()
  def decisions_query(filters \\ %{}) do
    filters = Map.new(filters)

    RoutingDecision
    |> apply_decision_filters(filters)
  end

  defp apply_decision_filters(query, filters) do
    case Map.get(filters, :since) do
      %DateTime{} = ts -> where(query, [d], d.inserted_at >= ^ts)
      _ -> query
    end
  end

  @doc "Fetches one routing decision by id, with associations preloaded. Raises if missing."
  @spec get_decision!(integer()) :: RoutingDecision.t()
  def get_decision!(id) do
    RoutingDecision
    |> Repo.get!(id)
    |> Repo.preload([:patient, :chosen_office, :queue_entry])
  end

  # --- VisitEvent ---

  @doc """
  Records one visit-lifecycle event. `attrs` is a map with at least `:type`;
  recognized keys: `:type, :visit_id, :queue_entry_id, :patient_id,
  :handoff_id, :actor_type, :actor_id, :payload, :occurred_at`. Missing
  `occurred_at` defaults to now.
  """
  @spec record_event(map()) :: {:ok, VisitEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(attrs) when is_map(attrs) do
    attrs =
      Map.put_new_lazy(attrs, :occurred_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    %VisitEvent{} |> VisitEvent.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Lists visit events newest-first. Optional filters: `:visit_id,
  :queue_entry_id, :patient_id, :handoff_id, :type, :actor_type, :actor_id,
  :since`. Used by callers that want all matching rows (e.g. tests, the
  internal LiveView board). Paginated callers should use `events_query/1`
  + `SchedulingWeb.Pagination` instead.
  """
  @spec list_events(map() | keyword()) :: [VisitEvent.t()]
  def list_events(filters \\ %{}) do
    filters
    |> events_query()
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> Repo.all()
  end

  @doc """
  Returns the events query with filters applied — composable, no ordering
  or limit. Controllers compose this with `SchedulingWeb.Pagination` for
  paginated reads.
  """
  @spec events_query(map() | keyword()) :: Ecto.Queryable.t()
  def events_query(filters \\ %{}) do
    filters = Map.new(filters)

    VisitEvent
    |> apply_event_filters(filters)
  end

  defp apply_event_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:visit_id, id}, q when not is_nil(id) -> where(q, [e], e.visit_id == ^id)
      {:queue_entry_id, id}, q when not is_nil(id) -> where(q, [e], e.queue_entry_id == ^id)
      {:patient_id, id}, q when not is_nil(id) -> where(q, [e], e.patient_id == ^id)
      {:handoff_id, id}, q when not is_nil(id) -> where(q, [e], e.handoff_id == ^id)
      {:type, t}, q when is_binary(t) -> where(q, [e], e.type == ^t)
      {:actor_type, t}, q when is_binary(t) -> where(q, [e], e.actor_type == ^t)
      {:actor_id, id}, q when is_binary(id) -> where(q, [e], e.actor_id == ^id)
      {:since, %DateTime{} = ts}, q -> where(q, [e], e.occurred_at >= ^ts)
      {_, _}, q -> q
    end)
  end

  @doc "Fetches one visit event by id. Raises if missing."
  @spec get_event!(integer()) :: VisitEvent.t()
  def get_event!(id), do: Repo.get!(VisitEvent, id)

  defp patient_name(%QueueEntry{patient: %{name: name}}) when is_binary(name), do: name
  defp patient_name(_entry), do: nil

  defp capability_names(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp capability_names(_), do: []

  defp eligible_office_names(candidates) when is_list(candidates) do
    Enum.map(candidates, fn %Candidate{office: office} -> office.name end)
  end

  defp eligible_office_names(_), do: []
end
