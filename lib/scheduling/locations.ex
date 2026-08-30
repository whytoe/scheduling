defmodule Scheduling.Locations do
  @moduledoc """
  Sites, projected from ac-core.

  ac-core owns the site list; `sync_from_core/1` pulls it and keeps the local
  cache in step. Everything else here reads that cache, so the board keeps its
  labels when the registry is briefly unreachable.

  ## What sync does and does not do

  It **upserts** by `core_location_id` and **deactivates** anything ac-core
  stopped returning. It never deletes: an office may point at a site, and a
  location that vanished from the registry is more likely a scope change or a
  transient than a decision to erase history. Deactivating is reversible and
  visible; deleting is neither.

  It also never touches `offices` — not the links, and not their timezones.
  Adopting a site's timezone is something an operator does when linking a room,
  not something a background sync does behind them. Slot generation reads
  `Office.timezone`, so silently changing it would move a room's whole calendar
  by an hour with no audit trail.

  ## Partial failure

  A sync that fails partway leaves the locations it already wrote. That is
  deliberate: a half-updated cache of a read-only projection is strictly better
  than an abandoned one, and the next run converges. The return value reports
  what happened rather than pretending it was atomic.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Scheduling.Core.Client
  alias Scheduling.Locations.Location
  alias Scheduling.Repo

  @typedoc "What a sync did. `deactivated` counts sites ac-core no longer returns."
  @type sync_result :: %{
          upserted: non_neg_integer(),
          deactivated: non_neg_integer(),
          pages: non_neg_integer()
        }

  @doc "Lists locations, active first then by name."
  @spec list_locations(keyword()) :: [Location.t()]
  def list_locations(opts \\ []) do
    Location
    |> maybe_only_active(Keyword.get(opts, :active))
    |> order_by([l], desc: l.active, asc: l.name, asc: l.id)
    |> Repo.all()
  end

  @doc "Fetches a location by local id. Raises if missing."
  @spec get_location!(term()) :: Location.t()
  def get_location!(id), do: Repo.get!(Location, id)

  @doc "Fetches by ac-core's id — the identity of record."
  @spec get_by_core_location_id(String.t()) :: Location.t() | nil
  def get_by_core_location_id(core_id) when is_binary(core_id) do
    Repo.get_by(Location, core_location_id: core_id)
  end

  @doc """
  Pulls the site list from ac-core and reconciles the local cache.

  Returns `{:ok, sync_result}`, or `{:error, reason}` if the first page could
  not be fetched. A failure partway through returns `{:error, reason}` too, but
  the locations already written stay — see the moduledoc.

  Opts: `:page_size` (default 100).
  """
  @spec sync_from_core(keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_from_core(opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 100)

    case fetch_all_pages(page_size) do
      {:ok, locations, pages} ->
        upserted = Enum.map(locations, &upsert!/1)
        seen = MapSet.new(upserted, & &1.core_location_id)

        {:ok,
         %{
           upserted: length(upserted),
           deactivated: deactivate_unseen(seen),
           pages: pages
         }}

      {:error, reason} ->
        Logger.error("Location sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Links an office to a site.

  When the office is still on the default `Etc/UTC` and the site publishes a
  timezone, the office adopts it — a room is in the place it is in, and making
  someone set that twice invites a mismatch that only shows up as a calendar an
  hour out. An office with a deliberately-set timezone is left alone.
  """
  @spec link_office(Scheduling.Offices.Office.t(), Location.t()) ::
          {:ok, Scheduling.Offices.Office.t()} | {:error, Ecto.Changeset.t()}
  def link_office(office, %Location{} = location) do
    attrs = %{"location_id" => location.id}

    attrs =
      if office.timezone in [nil, "Etc/UTC"] and is_binary(location.timezone) do
        Map.put(attrs, "timezone", location.timezone)
      else
        attrs
      end

    Scheduling.Offices.update_office(office, attrs)
  end

  # ac-core paginates; walk until we have them all. A page that fails aborts
  # the walk rather than syncing a partial list as if it were complete —
  # deactivate_unseen/1 would otherwise switch off every site on the pages we
  # never saw.
  defp fetch_all_pages(page_size), do: fetch_all_pages(1, page_size, [], 0)

  defp fetch_all_pages(page, page_size, acc, pages) do
    case Client.list_locations(page: page, page_size: page_size) do
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

  # Stop on an empty page even when `total` disagrees — trusting a bad total
  # would loop forever.
  defp more_pages?(_acc, _total, []), do: false
  defp more_pages?(acc, total, _data) when is_integer(total), do: length(acc) < total
  defp more_pages?(_acc, _total, _data), do: false

  defp upsert!(attrs) do
    core_id = attrs[:id]

    changes = %{
      core_location_id: core_id,
      core_practice_id: attrs[:practice_id],
      name: attrs[:name] || core_id,
      address: attrs[:address],
      timezone: attrs[:timezone],
      active: Map.get(attrs, :active, true),
      synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case get_by_core_location_id(core_id) do
      nil -> %Location{}
      existing -> existing
    end
    |> Location.changeset(changes)
    |> Repo.insert_or_update!()
  end

  defp deactivate_unseen(seen) do
    {count, _} =
      Location
      |> where([l], l.active == true and l.core_location_id not in ^MapSet.to_list(seen))
      |> Repo.update_all(set: [active: false])

    count
  end

  defp maybe_only_active(query, true), do: where(query, [l], l.active == true)
  defp maybe_only_active(query, false), do: where(query, [l], l.active == false)
  defp maybe_only_active(query, _), do: query
end
