defmodule Scheduling.Booking do
  @moduledoc """
  Booking: what is bookable, and (later) what has been booked.

  Today this covers **availability rules** — the recurring weekly patterns that
  slot generation expands into concrete instants. Slots and appointments follow;
  see `docs/booking.md` for the whole shape.

  Booking sits beside the live-queue engine rather than replacing it. A booking
  reserves time; the matcher still decides which room, unless the service is
  uniquely routable — see the binding rules in `docs/booking.md`.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Repo

  @doc """
  Lists availability rules, newest first.

  Opts:

    * `:office_id` — only this office's rules
    * `:active` — only active (`true`) or only inactive (`false`) rules
  """
  @spec list_availability_rules(keyword()) :: [AvailabilityRule.t()]
  def list_availability_rules(opts \\ []) do
    AvailabilityRule
    |> filter_by_office(Keyword.get(opts, :office_id))
    |> filter_by_active(Keyword.get(opts, :active))
    |> order_by([r], asc: r.day_of_week, asc: r.starts_at, asc: r.id)
    |> preload(:office)
    |> Repo.all()
  end

  @doc "Fetches a rule with its office preloaded. Raises if missing."
  @spec get_availability_rule!(term()) :: AvailabilityRule.t()
  def get_availability_rule!(id) do
    AvailabilityRule |> Repo.get!(id) |> Repo.preload(:office)
  end

  @doc "Creates an availability rule."
  @spec create_availability_rule(map()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def create_availability_rule(attrs \\ %{}) do
    %AvailabilityRule{}
    |> AvailabilityRule.changeset(attrs)
    |> Repo.insert()
    |> preload_office()
  end

  @doc """
  Updates an availability rule.

  Note the intended workflow for a *schedule change* is to end the old rule
  (`effective_until`) and write a new one, not to edit in place — see
  `Scheduling.Booking.AvailabilityRule`. This exists for corrections.
  """
  @spec update_availability_rule(AvailabilityRule.t(), map()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def update_availability_rule(%AvailabilityRule{} = rule, attrs) do
    rule
    |> AvailabilityRule.changeset(attrs)
    |> Repo.update()
    |> preload_office()
  end

  @doc """
  Retires a rule from `on` onward by setting `effective_until`, leaving the
  slots it already produced explicable.

  Deleting a rule outright would orphan generated slots and erase why they
  exist; `delete_availability_rule/1` is there for a rule created in error.
  """
  @spec retire_availability_rule(AvailabilityRule.t(), Date.t()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def retire_availability_rule(%AvailabilityRule{} = rule, %Date{} = on) do
    update_availability_rule(rule, %{effective_until: on, active: false})
  end

  @doc "Deletes a rule. For one created in error — prefer `retire_availability_rule/2`."
  @spec delete_availability_rule(AvailabilityRule.t()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def delete_availability_rule(%AvailabilityRule{} = rule), do: Repo.delete(rule)

  @doc "Returns a changeset for form tracking."
  @spec change_availability_rule(AvailabilityRule.t(), map()) :: Ecto.Changeset.t()
  def change_availability_rule(%AvailabilityRule{} = rule, attrs \\ %{}) do
    AvailabilityRule.changeset(rule, attrs)
  end

  @doc """
  The rules in force for an office on a given date.

  This is what generation asks per candidate day. Filtering happens in Elixir
  rather than SQL because `applies_on?/2` is the single definition of "in
  force" — duplicating that logic as a query would give two answers to drift
  apart.
  """
  @spec rules_in_force(integer(), Date.t()) :: [AvailabilityRule.t()]
  def rules_in_force(office_id, %Date{} = date) do
    office_id
    |> then(&list_availability_rules(office_id: &1, active: true))
    |> Enum.filter(&AvailabilityRule.applies_on?(&1, date))
  end

  defp filter_by_office(query, nil), do: query
  defp filter_by_office(query, office_id), do: where(query, [r], r.office_id == ^office_id)

  defp filter_by_active(query, nil), do: query
  defp filter_by_active(query, active), do: where(query, [r], r.active == ^active)

  defp preload_office({:ok, rule}), do: {:ok, Repo.preload(rule, :office)}
  defp preload_office(other), do: other
end
