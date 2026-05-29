defmodule Scheduling.Audit do
  @moduledoc """
  Records and lists routing decisions — a durable, human-readable log of every
  time the accept flow runs the matcher. The log is write-on-accept and
  read-only afterwards; it never feeds back into matching.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Audit.RoutingDecision
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

  @doc "Lists routing decisions, most recent first, with associations preloaded."
  @spec list_decisions() :: [RoutingDecision.t()]
  def list_decisions do
    RoutingDecision
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> Repo.all()
    |> Repo.preload([:patient, :chosen_office, :queue_entry])
  end

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
