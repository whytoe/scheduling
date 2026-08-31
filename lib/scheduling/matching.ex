defmodule Scheduling.Matching do
  @moduledoc """
  Routes a patient to an office based on required capabilities and free intake
  capacity.

  An office is **eligible** when it provides every required capability (the
  required set is a subset of the office's capabilities) and has free intake
  capacity (`current_load < intake_capacity`).

  Among eligible offices we pick the **best fit**: the one whose capability set
  most tightly matches the requirement, i.e. the smallest surplus of extra
  capabilities. This keeps specialized offices (CT, XRay, ...) available for the
  patients who actually need them rather than consuming them on simpler cases.
  Ties are broken by most free capacity, then by the offices' input order.

  The pure core (`eligible_offices/3`, `match/3`) operates over already-loaded
  structs. Current load is supplied as a `loads` map of `office.id => load`;
  offices absent from the map are assumed to have zero load. The context entry
  point `match_queue_entry/2` loads the data and delegates to the pure core.
  """

  import Ecto.Query, warn: false

  alias Scheduling.Catalog.Capability
  alias Scheduling.Matching.{Candidate, Result}
  alias Scheduling.Offices
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  @type loads :: %{optional(integer()) => non_neg_integer()}

  @doc """
  Returns the offices eligible for the given required capabilities, preserving
  input order.

  Eligible = required capabilities are a subset of the office's capabilities AND
  the office has free intake capacity. Each office must have its `:capabilities`
  preloaded.
  """
  @spec eligible_offices([struct()], [struct()], loads()) :: [struct()]
  def eligible_offices(required_capabilities, offices, loads \\ %{}) do
    required_keys = key_set(required_capabilities)
    Enum.filter(offices, &eligible?(&1, required_keys, loads))
  end

  @doc """
  Runs the full best-fit match and returns a `Result` exposing the eligible
  candidates, the chosen one, and a rationale.

  Returns a `Result` with `chosen: nil` when no office is eligible.
  """
  @spec match([struct()], [struct()], loads()) :: Result.t()
  def match(required_capabilities, offices, loads \\ %{}) do
    required_keys = key_set(required_capabilities)
    required_count = MapSet.size(required_keys)

    candidates =
      offices
      |> Enum.filter(&eligible?(&1, required_keys, loads))
      |> Enum.map(fn office ->
        %Candidate{
          office: office,
          surplus: MapSet.size(key_set(office.capabilities)) - required_count,
          free_capacity: free_capacity(office, loads)
        }
      end)
      |> Enum.sort_by(&{&1.surplus, -&1.free_capacity})

    chosen = List.first(candidates)

    %Result{
      required: required_capabilities,
      eligible: candidates,
      chosen: chosen,
      rationale: rationale(chosen, candidates, required_count)
    }
  end

  @doc """
  Context entry point: loads the offices and the queue entry's required
  capabilities, then delegates to the pure `match/3`.

  `loads` is the current per-office load map (`office.id => load`). Assignment
  tracking is owned by a later bead, so callers supply it explicitly; the
  default of `%{}` treats every office as idle.
  """
  @spec match_queue_entry(QueueEntry.t(), loads()) :: Result.t()
  def match_queue_entry(%QueueEntry{} = entry, loads \\ %{}, opts \\ []) do
    entry = Repo.preload(entry, :required_capabilities)

    # `:location_ids` narrows the candidate offices to the sites the acting
    # operator may work in. Without it the matcher would happily choose a room
    # the operator cannot see, producing an assignment they can neither find
    # nor undo — and placing a patient's record in front of staff at a site
    # that has no business with them.
    offices = Offices.list_offices(location_ids: Keyword.get(opts, :location_ids))

    match(entry.required_capabilities, offices, loads)
  end

  defp eligible?(office, required_keys, loads) do
    free_capacity(office, loads) > 0 and
      MapSet.subset?(required_keys, key_set(office.capabilities))
  end

  defp free_capacity(office, loads) do
    load = Map.get(loads, office.id, 0)
    max(office.intake_capacity - load, 0)
  end

  defp key_set(capabilities) do
    capabilities
    |> Enum.map(&cap_key/1)
    |> MapSet.new()
  end

  defp cap_key(%Capability{id: id}) when not is_nil(id), do: id
  defp cap_key(%Capability{name: name}), do: name
  defp cap_key(other), do: other

  defp rationale(nil, _candidates, required_count) do
    "No eligible office: none provides all #{required_count} required " <>
      "capability(ies) with free intake capacity."
  end

  defp rationale(%Candidate{} = chosen, candidates, _required_count) do
    office_name = chosen.office.name || "office ##{chosen.office.id}"

    "Chose #{office_name}: tightest capability match " <>
      "(#{chosen.surplus} surplus capability(ies), #{chosen.free_capacity} free " <>
      "intake slot(s)) among #{length(candidates)} eligible office(s)."
  end
end
