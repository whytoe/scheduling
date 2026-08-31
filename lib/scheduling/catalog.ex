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
  Deletes a capability, unless something live still requires it.

  ## Why this refuses rather than cascading

  `appointment_capabilities` and `queue_entry_capabilities` cascade on delete.
  That is right for the catalog joins — an office or a routing template simply
  stops offering it — and quietly wrong for anything attached to a patient.

  Deleting a capability does not make those bookings *unservable*; it makes
  them require **nothing**. A booking made for a CT scan silently becomes a
  booking for nothing, and a waiting patient's requirement vanishes so the
  matcher will route them anywhere. Neither fails. Neither is visible. The
  broken-commitment scan cannot see it either, because nothing is missing when
  nothing is required.

  So the check is here, before the delete: a capability required by a live
  appointment (`:booked` or `:arrived`) or an unfinished queue entry cannot be
  removed. Retire it from the offices and templates that offer it, let the
  work in flight finish, then delete.

  Returns `{:error, changeset}` with a usable message rather than a bare atom,
  so a form renders it without translating.
  """
  @spec delete_capability(Capability.t()) ::
          {:ok, Capability.t()} | {:error, Ecto.Changeset.t()}
  def delete_capability(%Capability{} = capability) do
    case capability_usage(capability.id) do
      {0, 0} ->
        Repo.delete(capability)

      {appointments, entries} ->
        {:error,
         capability
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:name, usage_message(appointments, entries))}
    end
  end

  @doc """
  How many live appointments and unfinished queue entries require a capability.

  Public because a UI wants to say *why* a delete is refused before someone
  clicks, not only after.
  """
  @spec capability_usage(integer()) :: {non_neg_integer(), non_neg_integer()}
  def capability_usage(capability_id) do
    appointments =
      from(ac in "appointment_capabilities",
        join: a in Scheduling.Booking.Appointment,
        on: a.id == ac.appointment_id,
        where: ac.capability_id == ^capability_id and a.status in [:booked, :arrived],
        select: count(ac.capability_id)
      )
      |> Repo.one()

    entries =
      from(qc in "queue_entry_capabilities",
        join: e in Scheduling.Queue.QueueEntry,
        on: e.id == qc.queue_entry_id,
        where: qc.capability_id == ^capability_id and e.status != :completed,
        select: count(qc.capability_id)
      )
      |> Repo.one()

    {appointments, entries}
  end

  defp usage_message(appointments, entries) do
    parts =
      []
      |> maybe_part(appointments, "appointment")
      |> maybe_part(entries, "waiting patient")
      |> Enum.reverse()

    "is still required by " <>
      Enum.join(parts, " and ") <>
      ". Remove it from the offices and services that offer it, and let that work finish, " <>
      "before deleting it."
  end

  defp maybe_part(parts, 0, _noun), do: parts
  defp maybe_part(parts, 1, noun), do: ["1 #{noun}" | parts]
  defp maybe_part(parts, n, noun), do: ["#{n} #{noun}s" | parts]

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

  @doc """
  Loads capabilities by id, ignoring ids that do not exist.

  Ignoring rather than erroring because the caller is usually expanding a
  client-supplied list, and a stale id should narrow the requirement rather
  than fail the whole request.
  """
  @spec list_capabilities_by_ids([term()]) :: [Capability.t()]
  def list_capabilities_by_ids(ids) when is_list(ids) do
    parsed =
      ids
      |> Enum.map(&normalise_id/1)
      |> Enum.reject(&is_nil/1)

    case parsed do
      [] -> []
      ids -> Capability |> where([c], c.id in ^ids) |> order_by([c], asc: c.name) |> Repo.all()
    end
  end

  defp normalise_id(id) when is_integer(id), do: id

  defp normalise_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> nil
    end
  end

  defp normalise_id(_id), do: nil

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
