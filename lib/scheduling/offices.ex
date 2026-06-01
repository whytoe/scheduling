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

  @doc "Lists all offices ordered by name, with capabilities preloaded."
  def list_offices do
    Office
    |> order_by(asc: :name)
    |> Repo.all()
    |> Repo.preload(:capabilities)
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
