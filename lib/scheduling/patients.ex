defmodule Scheduling.Patients do
  @moduledoc """
  The patient roster — a projection of ac-core's registry, not an authority.

  ac-core is the platform's system of record for patient identity. A row here
  caches the few fields scheduling needs (`docs/data-boundary.md`) keyed by
  `core_patient_id`; `resolve_from_core/1` is how one comes into existence.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Core.Client
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo

  @typedoc """
  Why a core-backed lookup failed.

  `:not_found` and `{:core_unavailable, reason}` are kept apart on purpose: the
  first means ac-core answered and does not have this patient, the second means
  we could not ask. A caller queueing an arrival should refuse the first and
  retry the second, and cannot do that if both arrive as `:error`.
  """
  @type core_error :: :not_found | {:core_unavailable, term()}

  @doc """
  Lists patients ordered by name. Optional id filters return at most one row
  (each of the three id columns carries a unique index):

    * `:core_patient_id`   (uuid) — the ac-core registry id, the identity of record
    * `:intake_patient_id` (uuid) — the intakeform UUID, primary integration key
    * `:external_id`       (string) — the check-in / queueing app's id
    * `:client_id`         (uuid) — the scheduling-owned id (deprecated)

  Filters compose via AND. Unknown keys are ignored. Used by the integration
  controller to skip the O(N) "list-and-filter-client-side" pattern (see
  sc-13t for the rationale).
  """
  def list_patients(filters \\ %{}) do
    filters = Map.new(filters)

    Patient
    |> apply_patient_filters(filters)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp apply_patient_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:core_patient_id, id}, q when is_binary(id) -> where(q, [p], p.core_patient_id == ^id)
      {:intake_patient_id, id}, q when is_binary(id) -> where(q, [p], p.intake_patient_id == ^id)
      {:external_id, id}, q when is_binary(id) -> where(q, [p], p.external_id == ^id)
      {:client_id, id}, q when is_binary(id) -> where(q, [p], p.client_id == ^id)
      {_, _}, q -> q
    end)
  end

  @doc "Fetches a patient by id. Raises if missing."
  def get_patient!(id), do: Repo.get!(Patient, id)

  @doc "Creates a patient."
  def create_patient(attrs \\ %{}) do
    %Patient{}
    |> Patient.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a patient."
  def update_patient(%Patient{} = patient, attrs) do
    patient
    |> Patient.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a patient. Cascades to their queue entries via FK on_delete: :delete_all."
  def delete_patient(%Patient{} = patient), do: Repo.delete(patient)

  @doc "Returns a changeset for tracking patient form changes."
  def change_patient(%Patient{} = patient, attrs \\ %{}) do
    Patient.changeset(patient, attrs)
  end

  @doc "Fetches the local projection of a core patient, if we have one."
  @spec get_by_core_patient_id(String.t()) :: Patient.t() | nil
  def get_by_core_patient_id(core_patient_id) when is_binary(core_patient_id) do
    Repo.get_by(Patient, core_patient_id: core_patient_id)
  end

  @doc """
  Returns the local projection of an ac-core patient, creating it from the
  registry if we have not seen them before.

  **Does not call ac-core when the row already exists.** This runs on the
  arrival path, where a patient is standing at a desk; paying an HTTP
  round-trip per lookup to re-confirm a name we already hold would be a poor
  trade. `refresh_from_core/1` is the explicit way to reconcile.

  Errors distinguish "ac-core does not have this patient" (`:not_found`) from
  "we could not reach ac-core" (`{:core_unavailable, reason}`) — see
  `t:core_error/0`. Never raises: a registry blip must not take down whatever
  is calling.
  """
  @spec resolve_from_core(String.t()) ::
          {:ok, Patient.t()} | {:error, core_error() | Ecto.Changeset.t()}
  def resolve_from_core(core_patient_id) when is_binary(core_patient_id) do
    case get_by_core_patient_id(core_patient_id) do
      %Patient{} = patient -> {:ok, patient}
      nil -> create_from_core(core_patient_id)
    end
  end

  @doc """
  Re-reads a patient from ac-core and updates the cached name if it has
  changed.

  Returns the patient either way; an unchanged name is not an error and not a
  write. Use where staleness matters — a nightly reconcile, or before printing
  something a human will rely on.
  """
  @spec refresh_from_core(Patient.t()) ::
          {:ok, Patient.t()} | {:error, core_error() | Ecto.Changeset.t()}
  def refresh_from_core(%Patient{core_patient_id: nil}), do: {:error, :not_found}

  def refresh_from_core(%Patient{core_patient_id: core_patient_id} = patient) do
    with {:ok, core_patient} <- fetch_core_patient(core_patient_id) do
      fresh = display_name(core_patient, core_patient_id)

      if fresh == patient.name do
        {:ok, patient}
      else
        update_patient(patient, %{"name" => fresh})
      end
    end
  end

  defp create_from_core(core_patient_id) do
    with {:ok, core_patient} <- fetch_core_patient(core_patient_id) do
      create_patient(%{
        "name" => display_name(core_patient, core_patient_id),
        "core_patient_id" => core_patient_id
      })
    end
  end

  defp fetch_core_patient(core_patient_id) do
    case Client.get_patient(core_patient_id) do
      {:ok, core_patient} -> {:ok, core_patient}
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  # ac-core scopes reads to the caller's practices, so a 404 covers both "no
  # such patient" and "not visible to this token" — indistinguishable to us by
  # design, and in either case asking again will not help. Everything else is
  # our side of the wire failing and is worth a retry.
  defp classify({:http_status, 404, _body}), do: :not_found
  defp classify(reason), do: {:core_unavailable, reason}

  # ac-core holds given and family names separately; `patients.name` is one
  # string. Reject blanks before joining so a missing surname does not leave a
  # trailing space, and nil never reaches the string.
  #
  # Falls back to the core id when the registry has neither name. That is
  # honest — it says "we have no name, here is the reference" — and it keeps a
  # patient at the desk from being blocked by a registry data gap. Inventing a
  # placeholder name would be worse: it reads as real.
  defp display_name(core_patient, core_patient_id) do
    [core_patient[:first_name], core_patient[:last_name]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> core_patient_id
      name -> name
    end
  end
end
