defmodule Scheduling.Repo.Migrations.AddScheduledForToQueueEntries do
  @moduledoc """
  Lets an entry be signed in for a time that has not arrived yet.

  The queueing service books a patient for 10:00 and tells us at 08:30. Until
  now the only way to represent that was a `waiting` entry, which the matcher
  would place immediately — a patient given a room ninety minutes early, and a
  room held for ninety minutes.

  Indexed with `status` because the only query that reads it is "which
  scheduled entries are now due", which runs every minute.
  """
  use Ecto.Migration

  def change do
    alter table(:queue_entries) do
      add :scheduled_for, :utc_datetime
    end

    create index(:queue_entries, [:status, :scheduled_for])
  end
end
