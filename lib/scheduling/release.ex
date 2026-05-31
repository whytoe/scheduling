defmodule Scheduling.Release do
  @moduledoc """
  Tasks meant to be run from a release (where Mix is unavailable).

  Invoke via the release binary, e.g.

      bin/scheduling eval "Scheduling.Release.migrate()"
      bin/scheduling eval "Scheduling.Release.rollback(Scheduling.Repo, 20260529070000)"
  """
  @app :scheduling

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
