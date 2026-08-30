defmodule Scheduling.Repo.Migrations.AddBookingFoundations do
  @moduledoc """
  The two fields booking cannot work without.

  `diagnoses.duration_minutes` — how long a service takes. Without it every
  service books the same length, which is wrong for anything real.

  `offices.timezone` — availability rules are written in the office's local
  time ("Mon-Fri 09:00-17:00" means nine in the morning where the room is),
  and slots are stored in UTC. Without a timezone, generation drifts an hour
  across a DST boundary and the calendar quietly becomes wrong. ac-core
  locations already publish one, so a synced office can inherit it later.
  """
  use Ecto.Migration

  def change do
    alter table(:diagnoses) do
      add :duration_minutes, :integer, null: false, default: 20
    end

    alter table(:offices) do
      add :timezone, :string, null: false, default: "Etc/UTC"
    end
  end
end
