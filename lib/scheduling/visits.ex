defmodule Scheduling.Visits do
  @moduledoc """
  Visit lifecycle: create a Visit when the patient signs in, list / show
  them, and end a Visit when the encounter concludes. Queue entries link
  to a Visit via `queue_entries.visit_id`.

  Create / end both emit a `Scheduling.Audit.VisitEvent` row inside the
  same transaction so the timeline stays consistent with the table.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Audit
  alias Scheduling.Repo
  alias Scheduling.Visits.Visit

  @doc "Lists visits, most recent first."
  def list_visits do
    Visit
    |> order_by([v], desc: v.started_at, desc: v.id)
    |> Repo.all()
    |> Repo.preload(:patient)
  end

  @doc "Fetches one visit by id, with patient and queue_entries preloaded. Raises if missing."
  def get_visit!(id) do
    Visit
    |> Repo.get!(id)
    |> Repo.preload([:patient, :queue_entries])
  end

  @doc """
  Creates a visit and records a `visit.created` event. `started_at` defaults
  to now if not supplied. `opts` may carry `:actor_type` and `:actor_id`.
  """
  def create_visit(attrs \\ %{}, opts \\ []) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:visit, Visit.changeset(%Visit{}, attrs))
    |> Ecto.Multi.run(:event, fn _repo, %{visit: visit} ->
      Audit.record_event(%{
        type: "visit.created",
        visit_id: visit.id,
        patient_id: visit.patient_id,
        actor_type: Keyword.get(opts, :actor_type),
        actor_id: Keyword.get(opts, :actor_id),
        occurred_at: visit.started_at,
        payload: %{}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{visit: visit}} -> {:ok, visit}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Ends a visit — sets status=:ended and stamps `ended_at` (defaults to now).
  Idempotent: ending an already-ended visit is a no-op success and does NOT
  record a duplicate event. `opts` may carry `:actor_type` and `:actor_id`.
  """
  def end_visit(visit, opts \\ [])

  def end_visit(%Visit{status: :ended} = visit, _opts), do: {:ok, visit}

  def end_visit(%Visit{} = visit, opts) do
    ended_at =
      Keyword.get(opts, :ended_at, DateTime.utc_now() |> DateTime.truncate(:second))

    Ecto.Multi.new()
    |> Ecto.Multi.update(:visit, Visit.changeset(visit, %{status: :ended, ended_at: ended_at}))
    |> Ecto.Multi.run(:event, fn _repo, %{visit: ended} ->
      Audit.record_event(%{
        type: "visit.ended",
        visit_id: ended.id,
        patient_id: ended.patient_id,
        actor_type: Keyword.get(opts, :actor_type),
        actor_id: Keyword.get(opts, :actor_id),
        occurred_at: ended.ended_at,
        payload: %{}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{visit: visit}} -> {:ok, visit}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end
end
