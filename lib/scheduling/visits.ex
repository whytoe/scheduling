defmodule Scheduling.Visits do
  @moduledoc """
  Visit lifecycle: create a Visit when the patient signs in, list / show
  them, and end a Visit when the encounter concludes. Queue entries link
  to a Visit via `queue_entries.visit_id`.
  """
  import Ecto.Query, warn: false

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

  @doc "Creates a visit. `started_at` defaults to now if not supplied."
  def create_visit(attrs \\ %{}) do
    %Visit{}
    |> Visit.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Ends a visit — sets status=:ended and stamps `ended_at` (defaults to now).
  Idempotent: ending an already-ended visit is a no-op success.
  """
  def end_visit(%Visit{status: :ended} = visit, _opts), do: {:ok, visit}

  def end_visit(%Visit{} = visit, opts) do
    ended_at =
      Keyword.get(opts, :ended_at, DateTime.utc_now() |> DateTime.truncate(:second))

    visit
    |> Visit.changeset(%{status: :ended, ended_at: ended_at})
    |> Repo.update()
  end

  def end_visit(%Visit{} = visit), do: end_visit(visit, [])
end
