defmodule Scheduling.Compliance.Client do
  @moduledoc """
  Thin HTTP client wrapping the intake-form-system REST API
  (`{INTAKE_API_URL}/openapi.json` describes it).

  Exposes `compliance_status/2`: given an opaque compliance reference and the
  patient's intake id, intake answers whether that patient has satisfied the
  forms the reference implies.

  ## Why the shape changed

  This client used to call `GET /responses?form_type=…`, which meant scheduling
  had to know — and therefore store — the clinical form-type names. Those are
  health data, and scheduling carries PII only (`docs/data-boundary.md`). The
  verdict endpoint moves that resolution to intake, which legitimately owns it.

  **This endpoint is a request to the intake team, not yet built.** Until it
  exists the call fails and the accept flow treats it as fail-closed, so the
  gate should stay disabled (`INTAKE_API_KEY` unset) until intake ships it. See
  `docs/integrations.md`.

  Configuration lives under `config :scheduling, Scheduling.Compliance` —
  `base_url`, `api_key`, `http_timeout_ms`.
  """

  @doc """
  Returns `{:ok, %{compliant: boolean}}` for the given compliance reference and
  patient, or `{:error, reason}`.

  `reference` is opaque to scheduling: intake resolves it to the set of forms
  the encounter requires and evaluates them. A 404 means intake does not
  recognise the reference, which is an error rather than a "no" — a reference
  we cannot resolve must not silently pass a patient through.
  """
  @spec compliance_status(String.t(), keyword()) ::
          {:ok, %{compliant: boolean()}} | {:error, term()}
  def compliance_status(reference, opts \\ []) when is_binary(reference) do
    config = config()

    case config.api_key do
      nil ->
        {:error, :api_key_missing}

      key ->
        Req.new(
          url: config.base_url <> "/compliance/status",
          params: build_params(reference, opts),
          headers: [{"authorization", "Bearer " <> key}],
          receive_timeout: config.http_timeout_ms
        )
        |> Req.get()
        |> handle_response()
    end
  end

  defp build_params(reference, opts) do
    case Keyword.get(opts, :patient_id) do
      pid when is_binary(pid) and pid != "" -> [reference: reference, patient_id: pid]
      _ -> [reference: reference]
    end
  end

  defp handle_response({:ok, %{status: 200, body: body}}) do
    case compliant_flag(body) do
      nil -> {:error, {:unexpected_body, body}}
      flag -> {:ok, %{compliant: flag}}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:http_status, status, body}}
  end

  defp handle_response({:error, exception}), do: {:error, exception}

  # Accept either casing; the intake API is camelCase elsewhere but the field
  # name is not yet fixed, so tolerate both rather than guess wrong.
  defp compliant_flag(%{"compliant" => flag}) when is_boolean(flag), do: flag
  defp compliant_flag(%{"isCompliant" => flag}) when is_boolean(flag), do: flag
  defp compliant_flag(_body), do: nil

  defp config do
    raw = Application.get_env(:scheduling, Scheduling.Compliance) || []

    %{
      base_url: Keyword.get(raw, :base_url, "http://localhost:3001/api/v1"),
      api_key: Keyword.get(raw, :api_key),
      http_timeout_ms: Keyword.get(raw, :http_timeout_ms, 5_000)
    }
  end
end
