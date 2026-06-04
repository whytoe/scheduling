defmodule Scheduling.Compliance.Client do
  @moduledoc """
  Thin HTTP client wrapping the intake-form-system REST API
  (`http://localhost:3001/api/v1/openapi.json` describes it).

  Exposes `list_completed_responses/2`, which pulls response metadata for a
  given form type filtered to `status=completed`. Pass `patient_id:` in opts
  to scope the call server-side via intake's index-direct `patient_id` query
  parameter (added by intakeform per scheduling's `sc-c9j` request) — the
  result is 0 or 1 row instead of up to `limit` rows for the whole org.
  Patient-side flag filtering still happens in `Scheduling.Compliance`
  because intake's filter is `status=completed`, not
  `status=completed AND flagged=false`.

  Configuration lives under `config :scheduling, Scheduling.Compliance` —
  `base_url`, `api_key`, `http_timeout_ms`.
  """

  @doc """
  Returns `{:ok, responses}` with a list of intake response metadata maps for
  the given form type with `status=completed`, or `{:error, reason}`.

  Opts:
    * `:patient_id` (string, optional) — intake patient UUID; when supplied,
      intake filters server-side via its `?patient_id=` parameter and the
      result is 0 or 1 row. Omit to fall back to the org-wide listing.

  Each response map has at least these keys (strings, as returned by intake):
  `"id"`, `"patientId"`, `"questionnaireId"`, `"formType"`, `"status"`,
  `"flagged"`, `"submittedAt"`.
  """
  @spec list_completed_responses(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def list_completed_responses(form_type, opts \\ []) when is_binary(form_type) do
    config = config()

    case config.api_key do
      nil ->
        {:error, :api_key_missing}

      key ->
        url = config.base_url <> "/responses"
        params = build_params(form_type, opts)

        Req.new(
          url: url,
          params: params,
          headers: [{"authorization", "Bearer " <> key}],
          receive_timeout: config.http_timeout_ms
        )
        |> Req.get()
        |> handle_response()
    end
  end

  defp build_params(form_type, opts) do
    base = [form_type: form_type, status: "completed", limit: 200]

    case Keyword.get(opts, :patient_id) do
      nil -> base
      "" -> base
      pid when is_binary(pid) -> [{:patient_id, pid} | base]
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
