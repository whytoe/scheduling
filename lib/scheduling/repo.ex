defmodule Scheduling.Repo do
  use Ecto.Repo,
    otp_app: :scheduling,
    adapter: Ecto.Adapters.Postgres
end
