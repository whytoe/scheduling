defmodule Scheduling.Patients do
  @moduledoc """
  The patient roster. Registration is owned by the external check-in app, so
  records here are intentionally minimal — display name + optional external id.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Repo
  alias Scheduling.Patients.Patient

  @doc """
  Lists patients ordered by name. Optional id filters return at most one row
  (each of the three id columns carries a unique index):

    * `:intake_patient_id` (uuid) — the intakeform UUID, primary integration key
    * `:external_id`       (string) — the check-in / queueing app's id
    * `:client_id`         (uuid) — the canonical scheduling-owned id

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
end
