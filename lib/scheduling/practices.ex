defmodule Scheduling.Practices do
  @moduledoc """
  Practices, projected from ac-core.

  Exists for one reason: a location's name is not unique. This deployment holds
  five sites and **three are called "Main Office"** — one per practice, which is
  what being bound to three practices produces. Two of those three carry no
  address either, so without the practice name an operator choosing between
  them has nothing at all to go on.

  `locations.core_practice_id` was already stored. Nothing had the name.

  ## Scope

  Read-only and deliberately thin. ac-core owns practices; scheduling holds
  just enough to label a site. There is no practice CRUD and there should not
  be one.

  Deactivation follows `Scheduling.Locations` exactly, including the guard: an
  empty response from ac-core deactivates nothing, because it cannot be told
  apart from losing permission to see them. That has already happened once on
  this deployment — see the note there.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Scheduling.Core.Client
  alias Scheduling.Practices.Practice
  alias Scheduling.Repo

  @typedoc "What a sync did. `withheld` counts deactivations the guard refused."
  @type sync_result :: %{
          upserted: non_neg_integer(),
          deactivated: non_neg_integer(),
          withheld: non_neg_integer(),
          pages: non_neg_integer()
        }

  @doc "Lists practices, active first then by name."
  @spec list_practices(keyword()) :: [Practice.t()]
  def list_practices(_opts \\ []) do
    Practice
    |> order_by([p], desc: p.active, asc: p.name, asc: p.id)
    |> Repo.all()
  end

  @doc "Fetches by ac-core's id — the identity of record."
  @spec get_by_core_practice_id(String.t()) :: Practice.t() | nil
  def get_by_core_practice_id(core_id) when is_binary(core_id) do
    Repo.get_by(Practice, core_practice_id: core_id)
  end

  @doc """
  Pulls the practice list from ac-core and reconciles the local cache.

  Same contract as `Scheduling.Locations.sync_from_core/1`, including that an
  empty response deactivates nothing.
  """
  @spec sync_from_core(keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_from_core(opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 100)

    case fetch_all_pages(page_size) do
      {:ok, practices, pages} ->
        upserted = Enum.map(practices, &upsert!/1)
        seen = MapSet.new(upserted, & &1.core_practice_id)
        {deactivated, withheld} = deactivate_unseen(seen)

        {:ok,
         %{
           upserted: length(upserted),
           deactivated: deactivated,
           withheld: withheld,
           pages: pages
         }}

      {:error, reason} ->
        Logger.error("Practice sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_all_pages(page_size), do: fetch_all_pages(1, page_size, [], 0)

  defp fetch_all_pages(page, page_size, acc, pages) do
    case Client.list_practices(page: page, page_size: page_size) do
      {:ok, %{data: data} = envelope} ->
        acc = acc ++ data
        total = Map.get(envelope, :total)

        if more_pages?(acc, total, data) do
          fetch_all_pages(page + 1, page_size, acc, pages + 1)
        else
          {:ok, acc, pages + 1}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp more_pages?(_acc, _total, []), do: false
  defp more_pages?(acc, total, _data) when is_integer(total), do: length(acc) < total
  defp more_pages?(_acc, _total, _data), do: false

  defp upsert!(attrs) do
    core_id = attrs[:id]

    changes = %{
      core_practice_id: core_id,
      name: attrs[:name] || attrs[:slug] || core_id,
      slug: attrs[:slug],
      core_organization_id: attrs[:organization_id],
      active: true,
      synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case get_by_core_practice_id(core_id) do
      nil -> %Practice{}
      existing -> existing
    end
    |> Practice.changeset(changes)
    |> Repo.insert_or_update!()
  end

  # See Scheduling.Locations.deactivate_unseen/1 — same rule, same reason. An
  # empty response is read as a scope change rather than as every practice
  # closing at once.
  defp deactivate_unseen(seen) do
    candidates =
      Practice
      |> where([p], p.active == true and p.core_practice_id not in ^MapSet.to_list(seen))

    would_deactivate = Repo.aggregate(candidates, :count)

    if MapSet.size(seen) == 0 and would_deactivate > 0 do
      Logger.error(
        "Practice sync withheld #{would_deactivate} deactivation(s): ac-core returned an " <>
          "empty practice list. Treating it as a scope change — check the client's practice " <>
          "binding (GET /v1/self/practices)."
      )

      {0, would_deactivate}
    else
      {count, _} = Repo.update_all(candidates, set: [active: false])
      if count > 0, do: Logger.warning("Practice sync deactivated #{count} practice(s)")
      {count, 0}
    end
  end
end
