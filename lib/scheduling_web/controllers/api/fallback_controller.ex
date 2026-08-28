defmodule SchedulingWeb.Api.FallbackController do
  @moduledoc """
  Translates `{:error, ...}` tuples returned by API controllers into JSON
  responses. Each `:action_fallback` on an API controller delegates here so
  the handler functions only deal with the happy path.

  Every response goes through `SchedulingWeb.ErrorEnvelope` so the API exposes
  the single unified error envelope.
  """
  use SchedulingWeb, :controller

  alias Ecto.Changeset
  alias SchedulingWeb.ErrorEnvelope

  def call(conn, {:error, %Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorEnvelope.changeset_envelope(changeset))
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(ErrorEnvelope.error_envelope("not_found", "Resource not found"))
  end
end
