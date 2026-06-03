defmodule Scheduling.Compliance.Client do
  @moduledoc """
  Thin HTTP client wrapping the intake-form-system REST API
  (`http://localhost:3001/api/v1/openapi.json` describes it).

  Only the endpoint we need today is exposed: `list_completed_responses/1`,
  which pulls response metadata for a given form type filtered to
  `status=completed`. Patient-side filtering happens upstream in
  `Scheduling.Compliance` because the intake API doesn't currently accept
  a `patient_id` query parameter.

  Configuration lives under `config :scheduling, Scheduling.Compliance` —
  `base_url`, `api_key`, `http_timeout_ms`.
  """

  @doc """
  Returns `{:ok, responses}` with a list of intake response metadata maps for
  the given form type with `status=completed`, or `{:error, reason}`.

  Each response map has at least these keys (strings, as returned by intake):
  `"id"`, `"patientId"`, `"questionnaireId"`, `"formType"`, `"status"`,
  `"flagged"`, `"submittedAt"`.
  """
  @spec list_completed_responses(String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def list_completed_responses(form_type) when is_binary(form_type) do
    config = config()

    case config.api_key do
      nil ->
        {:error, :api_key_missing}

      key ->
        url = config.base_url <> "/responses"

        Req.new(
          url: url,
          params: [form_type: form_type, status: "completed", limit: 200],
          headers: [{"authorization", "Bearer " <> key}],
          receive_timeout: config.http_timeout_ms
        )
        |> Req.get()
        |> handle_response()
    end
  end

  defp handle_response({:ok, %{status: 200, body: body}}) do
    {:ok, normalize_list(body)}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:http_status, status, body}}
  end

  defp handle_response({:error, exception}), do: {:error, exception}

  # The ResponseList schema in the intake spec wraps results — accept either
  # a raw list (some test fixtures) or {"data": [...]} / {"items": [...]}.
  defp normalize_list(body) when is_list(body), do: body
  defp normalize_list(%{"data" => items}) when is_list(items), do: items
  defp normalize_list(%{"items" => items}) when is_list(items), do: items
  defp normalize_list(%{"responses" => items}) when is_list(items), do: items
  defp normalize_list(_), do: []

  defp config do
    raw = Application.get_env(:scheduling, Scheduling.Compliance) || []

    %{
      base_url: Keyword.get(raw, :base_url, "http://localhost:3001/api/v1"),
      api_key: Keyword.get(raw, :api_key),
      http_timeout_ms: Keyword.get(raw, :http_timeout_ms, 5_000)
    }
  end
end
