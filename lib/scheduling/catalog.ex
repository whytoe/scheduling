defmodule Scheduling.Catalog do
  @moduledoc """
  The capability and diagnosis catalog. Capabilities (XRay, CT Scan, Dialysis…)
  are the labels offices declare and queue entries require; the matcher reads
  them when routing patients to offices.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Repo
  alias Scheduling.Catalog.Capability
  alias Scheduling.Catalog.Diagnosis

  @doc "Lists the capability catalog ordered by name."
  def list_capabilities do
    Capability
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc "Fetches a capability by id. Raises if missing."
  def get_capability!(id), do: Repo.get!(Capability, id)

  @doc "Creates a capability."
  def create_capability(attrs \\ %{}) do
    %Capability{}
    |> Capability.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a capability."
  def update_capability(%Capability{} = capability, attrs) do
    capability
    |> Capability.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a capability. Foreign keys on `office_capabilities`,
  `diagnosis_capabilities`, and `queue_entry_capabilities` cascade, so the
  capability is removed from every office, diagnosis default, and pending
  queue requirement that referenced it.
  """
  def delete_capability(%Capability{} = capability), do: Repo.delete(capability)

  @doc "Returns a changeset for tracking capability form changes."
  def change_capability(%Capability{} = capability, attrs \\ %{}) do
    Capability.changeset(capability, attrs)
  end

  # --- Diagnoses ---

  @doc "Lists diagnoses ordered by name, with default capabilities preloaded."
  def list_diagnoses do
    Diagnosis
    |> order_by(asc: :name)
    |> Repo.all()
    |> Repo.preload(:capabilities)
  end

  @doc "Fetches a diagnosis by id with capabilities preloaded. Raises if missing."
  def get_diagnosis!(id) do
    Diagnosis
    |> Repo.get!(id)
    |> Repo.preload(:capabilities)
  end

  @doc """
  Non-raising `get_diagnosis!/1`. Returns `:error` for a missing row or an id
  that isn't an integer — callers expanding a client-supplied `diagnosis_id`
  need to turn bad input into a validation error, not a 500.
  """
  @spec fetch_diagnosis(term()) :: {:ok, Diagnosis.t()} | :error
  def fetch_diagnosis(id) when is_integer(id) do
    case Repo.get(Diagnosis, id) do
      nil -> :error
      diagnosis -> {:ok, Repo.preload(diagnosis, :capabilities)}
    end
  end

  def fetch_diagnosis(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> fetch_diagnosis(int_id)
      _ -> :error
    end
  end

  def fetch_diagnosis(_id), do: :error

  @doc """
  Fetches a routing template by its `code` — the catalog's stable, externally
  quotable key.

  External systems reference a service by code, never by our row id: an id is
  an implementation detail of this database, and a code is a contract. Codes
  are also what lets the reference stay **opaque** — a caller can send
  `svc_7a2f` and scheduling resolves it to the capabilities that service
  needs, without either side putting a clinical label on the wire. See
  `docs/data-boundary.md`.
  """
  @spec fetch_diagnosis_by_code(term()) :: {:ok, Diagnosis.t()} | :error
  def fetch_diagnosis_by_code(code) when is_binary(code) and code != "" do
    case Repo.get_by(Diagnosis, code: code) do
      nil -> :error
      diagnosis -> {:ok, Repo.preload(diagnosis, :capabilities)}
    end
  end

  def fetch_diagnosis_by_code(_code), do: :error

  @doc "Creates a diagnosis. Accepts `capability_ids` to set its default required capabilities."
  def create_diagnosis(attrs \\ %{}) do
    %Diagnosis{capabilities: []}
    |> diagnosis_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a diagnosis. Accepts `capability_ids` to replace its default capabilities."
  def update_diagnosis(%Diagnosis{} = diagnosis, attrs) do
    diagnosis
    |> Repo.preload(:capabilities)
    |> diagnosis_changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a diagnosis and its capability-default associations."
  def delete_diagnosis(%Diagnosis{} = diagnosis), do: Repo.delete(diagnosis)

  @doc "Returns a changeset for tracking diagnosis form changes."
  def change_diagnosis(%Diagnosis{} = diagnosis, attrs \\ %{}) do
    diagnosis
    |> Repo.preload(:capabilities)
    |> diagnosis_changeset(attrs)
  end

  defp diagnosis_changeset(diagnosis, attrs) do
    diagnosis
    |> Diagnosis.changeset(attrs)
    |> put_capabilities(attrs)
  end

  defp put_capabilities(changeset, attrs) do
    case fetch_capability_ids(attrs) do
      :error -> changeset
      {:ok, ids} -> Ecto.Changeset.put_assoc(changeset, :capabilities, load_capabilities(ids))
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
