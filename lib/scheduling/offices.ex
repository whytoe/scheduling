defmodule Scheduling.Offices do
  @moduledoc """
  Per-office configuration: offices, their intake capacity, and the set of
  capabilities each office provides. This is the configuration the matcher
  reads when routing patients to offices.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Repo
  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices.Office

  # NOTE: capability CRUD (including `list_capabilities/0`) now lives in
  # `Scheduling.Catalog`. This module only consumes capabilities to attach
  # them to offices via the office_capabilities join.

  @doc """
  Lists offices ordered by name, with capabilities and location preloaded.

  `:location_ids` restricts the result to offices at those ac-core locations.
  `nil` — the default — applies no filter, which is what an unscoped identity,
  an admin, and an auth-disabled deployment all get. See
  `Scheduling.Auth.Scope.location_ids/1`.

  Offices with no location are **always included**. A room that has not been
  linked to a site cannot be attributed to one, and dropping it would make it
  vanish from the board with nothing to explain why; an operator would see a
  shorter list and no error. Including it errs toward the behaviour that
  existed before scoping, which is the safer direction for a filter added to a
  running system.
  """
  @spec list_offices(keyword()) :: [Office.t()]
  def list_offices(opts \\ []) do
    Office
    |> scope_to_locations(Keyword.get(opts, :location_ids))
    |> order_by(asc: :name)
    |> Repo.all()
    |> Repo.preload([:capabilities, :location])
  end

  @doc """
  Offices a patient may actually be placed in.

  `list_offices/1` minus the rooms at a site ac-core has deactivated. Every
  assignment path reads this; every display path reads `list_offices/1`.

  That split is the whole point, and it is why this is a separate function
  rather than an option. A deactivated site's rooms **stay on the board** —
  hiding them would make rooms disappear with nothing on screen to explain it,
  which is the failure this codebase has been bitten by more than any other.
  They are shown and they decline assignment.

  An office with no location is assignable, for the same reason it is visible:
  a room not yet attached to a site cannot be attributed to one, and refusing
  to place patients in it would break a working deployment the moment anyone
  added a room without linking it.

  ## Why a named function and not `list_offices(assignable: true)`

  A new assignment path would get an option wrong silently. It cannot get the
  wrong function name silently — `list_offices/1` in a routing decision reads
  as an obvious mistake to anybody reviewing it.
  """
  @spec list_assignable_offices(keyword()) :: [Office.t()]
  def list_assignable_offices(opts \\ []) do
    opts
    |> list_offices()
    |> Enum.reject(&at_inactive_location?/1)
  end

  defp at_inactive_location?(%Office{location: %{active: false}}), do: true
  defp at_inactive_location?(_office), do: false

  defp scope_to_locations(query, nil), do: query

  defp scope_to_locations(query, location_ids) do
    from(o in query,
      left_join: l in assoc(o, :location),
      where: is_nil(o.location_id) or l.core_location_id in ^location_ids
    )
  end

  @doc "Fetches a single office by id with capabilities preloaded. Raises if missing."
  def get_office!(id) do
    Office
    |> Repo.get!(id)
    |> Repo.preload(:capabilities)
  end

  @doc "Creates an office. Accepts `capability_ids` to assign capabilities."
  def create_office(attrs \\ %{}) do
    %Office{capabilities: []}
    |> office_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an office. Accepts `capability_ids` to replace its capabilities."
  def update_office(%Office{} = office, attrs) do
    office
    |> Repo.preload(:capabilities)
    |> office_changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes an office and its capability associations."
  def delete_office(%Office{} = office) do
    Repo.delete(office)
  end

  @doc "Returns a changeset for tracking office form changes."
  def change_office(%Office{} = office, attrs \\ %{}) do
    office
    |> Repo.preload(:capabilities)
    |> office_changeset(attrs)
  end

  defp office_changeset(office, attrs) do
    office
    |> Office.changeset(attrs)
    |> put_capabilities(attrs)
  end

  defp put_capabilities(changeset, attrs) do
    case fetch_capability_ids(attrs) do
      :error ->
        changeset

      {:ok, ids} ->
        Ecto.Changeset.put_assoc(changeset, :capabilities, load_capabilities(ids))
    end
  end

  defp fetch_capability_ids(attrs) do
    cond do
      Map.has_key?(attrs, :capability_ids) -> {:ok, attrs[:capability_ids]}
      Map.has_key?(attrs, "capability_ids") -> {:ok, attrs["capability_ids"]}
      true -> :error
    end
  end

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
end
