defmodule SchedulingWeb.Api.FallbackController do
  @moduledoc """
  Translates `{:error, ...}` tuples returned by API controllers into JSON
  responses. Each `:action_fallback` on an API controller delegates here so
  the handler functions only deal with the happy path.
  """
  use SchedulingWeb, :controller

  alias Ecto.Changeset

  def call(conn, {:error, %Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: traverse_errors(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  defp traverse_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
