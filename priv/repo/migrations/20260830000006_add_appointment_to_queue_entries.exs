defmodule Scheduling.Repo.Migrations.AddAppointmentToQueueEntries do
  @moduledoc """
  Which booking a queue entry arrived from, when it arrived from one.

  Nullable: walk-ins have no appointment, and they remain the majority of what
  this queue handles.

  `nilify_all` rather than `delete_all` — deleting an appointment must never
  delete the record that a patient was seen. The queue entry and its audit
  trail outlive the booking that produced it.
  """
  use Ecto.Migration

  def change do
    alter table(:queue_entries) do
      add :appointment_id, references(:appointments, on_delete: :nilify_all)
    end

    create index(:queue_entries, [:appointment_id])
  end
end
