defmodule Scheduling.Repo.Migrations.CreateRevokedSessions do
  use Ecto.Migration

  def change do
    create table(:revoked_sessions) do
      # "sid" revokes one session; "sub" revokes every session for a subject.
      # Back-channel logout tokens may carry either, so both are storable.
      add :kind, :string, null: false
      add :value, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # A logout notification can be delivered more than once; upsert on this.
    create unique_index(:revoked_sessions, [:kind, :value])

    # Drives the sweep, which is the only query that scans by time.
    create index(:revoked_sessions, [:expires_at])
  end
end
