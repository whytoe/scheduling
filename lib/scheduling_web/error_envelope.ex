defmodule SchedulingWeb.ErrorEnvelope do
  @moduledoc """
  Single source of truth for the JSON API error envelope.

  Every JSON error response — validation failures, not-found, compliance,
  and generic Phoenix errors — is rendered through this module so the API
  exposes exactly ONE error shape:

      {
        "error": {
          "code": "compliance_failed",
          "message": "human-readable summary",
          "details": { ... }            // optional, structured
        }
      }

  This is the intended v1 error contract (see bead sc-2y8). When the API grows
  a `/v2`, a new envelope would be introduced alongside it rather than mutating
  this one.
  """

  alias Ecto.Changeset

  @doc """
  Builds the unified error envelope map.

  `details` is omitted entirely when `nil` so responses without structured
  detail stay compact.
  """
  def error_envelope(code, message, details \\ nil)

  def error_envelope(code, message, nil) do
    %{error: %{code: to_string(code), message: message}}
  end

  def error_envelope(code, message, details) do
    %{error: %{code: to_string(code), message: message, details: details}}
  end

  @doc """
  Builds the envelope for an `Ecto.Changeset` validation failure. The
  field → messages map is placed under `details.fields`.
  """
  def changeset_envelope(%Changeset{} = changeset) do
    error_envelope(
      "validation_failed",
      "One or more fields are invalid",
      %{fields: traverse_errors(changeset)}
    )
  end

  defp traverse_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
