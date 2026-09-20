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

  ## An empty response deactivates nothing

  `sync_from_core/1` cannot tell "ac-core no longer has this site" from
  "ac-core no longer *shows* us this site". The first is a closure; the second
  is a scope change, and the sites are still there.

  The second is far more likely. This deployment received an empty list on
  every hourly sync from 2026-09-05 to 2026-09-19 because its ac-core client
  was bound to no practices, and escaped a total wipe only because no locations
  had been projected yet.

  So an empty response is read as a scope change and deactivates nothing;
  `withheld` in the result says how many were spared. A *non-empty* response is
  taken at face value even when it matches nothing we hold — at that point
  ac-core has told us something specific.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Scheduling.Core.Client
  alias Scheduling.Locations.Location
  alias Scheduling.Repo

  @typedoc """
  What a sync did.

  `deactivated` counts sites ac-core no longer returns. `withheld` counts sites
  it would have deactivated but did not, because doing so would have switched
  off every active location at once — see `deactivate_unseen/1`.
  """
  @type sync_result :: %{
          upserted: non_neg_integer(),
          deactivated: non_neg_integer(),
          withheld: non_neg_integer(),
          pages: non_neg_integer()
        }

  @doc "Lists locations, active first then by name."
  @spec list_locations(keyword()) :: [Location.t()]
  def list_locations(opts \\ []) do
    Location
    |> maybe_only_active(Keyword.get(opts, :active))
    |> order_by([l], desc: l.active, asc: l.name, asc: l.id)
    |> Repo.all()
    |> Repo.preload(:practice)
  end

  @doc "Fetches a location by local id. Raises if missing."
  @spec get_location!(term()) :: Location.t()
  def get_location!(id), do: Repo.get!(Location, id)

  @doc """
  An unambiguous label for a site.

  `"Sunshine Pediatrics — Main Office"`, or just the site name when the
  practice is unknown.

  Exists because a site name is **not unique**: this deployment holds five and
  three are called "Main Office", one per practice, and two of those three have
  no address. Anything that offers a choice between sites — an office/location
  picker, a board label, an audit line — has to use this rather than `name`,
  or it presents two identical options.

  Requires `:practice` to be preloaded; an unloaded association is treated as
  unknown rather than raising, since a missing label is not worth an exception
  in a render.
  """
  @spec label(Location.t()) :: String.t()
  def label(%Location{} = location) do
    case location.practice do
      %{name: practice} when is_binary(practice) and practice != "" ->
        practice <> " — " <> (location.name || location.core_location_id)

      _unknown ->
        location.name || location.core_location_id
    end
  end

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
        {deactivated, withheld} = deactivate_unseen(seen)

        {:ok,
         %{
           upserted: length(upserted),
           deactivated: deactivated,
           withheld: withheld,
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

  # Switches off the sites ac-core stopped returning — unless that would be all
  # of them, in which case it switches off nothing and says so.
  #
  # The guard exists because this function cannot tell two very different events
  # apart. "ac-core no longer has this site" is a closure. "ac-core no longer
  # SHOWS us this site" is a scope or permissions change, and the sites are
  # still there. The second is far more likely — this deployment spent
  # 2026-09-05 to 2026-09-19 receiving an empty list on every sync because its
  # ac-core client was bound to no practices, and only escaped a total wipe
  # because no locations had been projected yet.
  #
  # A total collapse is therefore read as a scope change, not as every clinic
  # closing on the same afternoon. The cost of being wrong that way is a stale
  # `active` flag; the cost of being wrong the other way, once
  # `Scheduling.Offices` honours the flag, is every office becoming unroutable
  # with nothing on screen to explain it.
  #
  # The rule is deliberately narrow: **an empty response deactivates nothing.**
  # Not "more than half", not "every id changed" — those are also suspicious,
  # but a practice legitimately leaving our binding would trip the first and a
  # re-provision would trip the second, and a threshold nobody can predict is
  # worse than a rule anyone can state. A non-empty response is taken at face
  # value even when it disagrees with everything we hold, because at that point
  # ac-core has told us something specific.
  defp deactivate_unseen(seen) do
    candidates =
      Location
      |> where([l], l.active == true and l.core_location_id not in ^MapSet.to_list(seen))

    would_deactivate = Repo.aggregate(candidates, :count)

    if MapSet.size(seen) == 0 and would_deactivate > 0 do
      Logger.error(
        "Location sync withheld #{would_deactivate} deactivation(s): ac-core returned an " <>
          "empty site list, which would have deactivated every active location. Treating " <>
          "it as a scope change rather than as every site closing at once — check the " <>
          "client's practice binding (GET /v1/self/practices)."
      )

      {0, would_deactivate}
    else
      {count, _} = Repo.update_all(candidates, set: [active: false])
      if count > 0, do: Logger.warning("Location sync deactivated #{count} site(s)")
      {count, 0}
    end
  end

  defp maybe_only_active(query, true), do: where(query, [l], l.active == true)
  defp maybe_only_active(query, false), do: where(query, [l], l.active == false)
  defp maybe_only_active(query, _), do: query
end
