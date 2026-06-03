defmodule Scheduling.Patients do
  @moduledoc """
  The patient roster. Registration is owned by the external check-in app, so
  records here are intentionally minimal — display name + optional external id.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Repo
  alias Scheduling.Patients.Patient

  @doc "Lists patients ordered by name."
  def list_patients do
    Patient
    |> order_by(asc: :name)
    |> Repo.all()
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
