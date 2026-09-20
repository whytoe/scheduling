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

  @doc """
  Loads catalog seed data (capabilities, diagnoses, diagnosis→capability defaults).
  Idempotent — seeds.exs upserts with `on_conflict: :nothing`, so it's safe to
  re-run on every boot.
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &run_seeds/1)
    end
  end

  defp run_seeds(_repo) do
    seed_script = Application.app_dir(@app, "priv/repo/seeds.exs")
    if File.exists?(seed_script), do: Code.eval_file(seed_script)
  end

  @doc """
  Pulls practices and locations from ac-core now, instead of waiting for the
  hourly pass.

      bin/scheduling eval "Scheduling.Release.sync_locations()"

  `Scheduling.Locations.Syncer` already has `nudge/0` for exactly this, and
  **nothing can reach it**: the release runs without distribution, so
  `bin/scheduling rpc` fails `:noconnection`, and `eval` runs a separate BEAM
  that cannot see the running process. Redeploying does not help either — a
  config-identical redeploy renders no manifest change, so Kubernetes rolls
  nothing. That left "wait up to an hour" and "restart production" as the only
  ways to make the site list current, and the second one did not work.

  This starts only what the sync needs and deliberately **not the endpoint**,
  which is why it can run alongside a live release rather than fighting it for
  port 4000.

  Prints what happened. Returns `:ok` even when a pass fails — the output is
  the result, and an exception here would be less readable than the log line
  that preceded it.
  """
  def sync_locations do
    load_app()

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:oidcc)

    children =
      [
        Scheduling.Repo,
        Scheduling.Auth.Provider.child_spec_if_enabled(),
        Scheduling.Auth.ServiceToken
      ]
      |> Enum.reject(&is_nil/1)

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    # Discovery is asynchronous, and a sync started before it lands fails
    # `:provider_not_ready` — the same reason the supervised syncer waits
    # before its first pass.
    Process.sleep(4_000)

    report("Practices", Scheduling.Practices.sync_from_core())
    report("Locations", Scheduling.Locations.sync_from_core())

    Supervisor.stop(supervisor)
    :ok
  end

  defp report(what, {:ok, result}) do
    IO.puts(
      "#{what}: #{result.upserted} upserted, #{result.deactivated} deactivated, " <>
        "#{result.withheld} withheld, #{result.pages} page(s)"
    )
  end

  defp report(what, {:error, reason}), do: IO.puts("#{what}: FAILED #{inspect(reason)}")

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
