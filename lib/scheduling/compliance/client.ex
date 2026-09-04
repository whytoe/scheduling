defmodule Scheduling.Compliance.Client do
  @moduledoc """
  Thin HTTP client wrapping the intake-form-system REST API
  (`{INTAKE_API_URL}/openapi.json` describes it).

  Exposes `satisfied_refs/2`: given a patient's intake id and the compliance
  references an encounter requires, it returns the subset that already has a
  completed response on file. Scheduling compares that against what it required
  and decides — see `Scheduling.Compliance`.

  ## Why this shape, and not a verdict endpoint

  We originally asked intake for `GET /compliance/status` returning
  pass/fail. They declined, correctly, for two reasons worth keeping written
  down (`docs/intake-compliance-reply.md`):

    * The policy — *which* forms an encounter requires — is scheduling's. A
      verdict endpoint would have made intake the authority on a decision whose
      inputs (diagnosis, appointment, queue) it cannot see.
    * A bare pass/fail cannot be explained at a front desk. Knowing *which*
      requirement is outstanding is what lets someone tell the patient what to
      do about it.

  So intake answers a factual question about its own data and scheduling keeps
  the verdict. References are random per `(organization_id, form_type)` and
  opaque here — not a hash of the form-type name, so they cannot be recovered
  by guessing plausible names.

  ## One request per reference, for now

  `satisfied_refs/2` takes a list because the batch shape is what we want, but
  it currently issues one request per reference. Batching needs intake to
  return the reference on each row; without that a multi-ref query says how
  many requirements are met but not which, and "one of your two is satisfied"
  is not an answer the gate can use. The interface is already list-shaped so
  swapping in a real batch call is a change to this function alone.

  Configuration lives under `config :scheduling, Scheduling.Compliance` —
  `base_url`, `api_key`, `http_timeout_ms`.
  """

  @typedoc """
  `:unknown_reference` is separated from every other failure on purpose. It
  means intake did not recognise a reference we sent, which is a configuration
  fault on our side — a stale `cref_` left behind after a form type was
  retired. It must not be reported as a patient missing paperwork.
  """
  @type error :: {:unknown_reference, String.t()} | term()

  @doc """
  Returns `{:ok, MapSet.t()}` of the references that have a completed response
  on file for this patient, or `{:error, reason}`.

  A reference intake does not recognise fails the whole call rather than being
  treated as unsatisfied: a reference we cannot resolve must not silently
  block, nor silently pass.
  """
  @spec satisfied_refs(String.t(), [String.t()]) :: {:ok, MapSet.t()} | {:error, error()}
  def satisfied_refs(patient_id, refs) when is_binary(patient_id) and is_list(refs) do
    config = config()

    case config.api_key do
      nil ->
        {:error, :api_key_missing}

      key ->
        refs
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, MapSet.new()}, fn ref, {:ok, acc} ->
          case completed?(config, key, patient_id, ref) do
            {:ok, true} -> {:cont, {:ok, MapSet.put(acc, ref)}}
            {:ok, false} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp completed?(config, key, patient_id, ref) do
    Req.new(
      url: config.base_url <> "/responses",
      params: [patient_id: patient_id, compliance_ref: ref, status: "completed", limit: 1],
      headers: [{"authorization", "Bearer " <> key}],
      receive_timeout: config.http_timeout_ms
    )
    |> Req.get()
    |> handle_response(ref)
  end

  # 400 is intake's answer for a reference it cannot resolve — agreed in
  # docs/intake-compliance-reply.md precisely so a retired reference is loud
  # rather than degrading to a skip.
  defp handle_response({:ok, %{status: 400}}, ref), do: {:error, {:unknown_reference, ref}}

  defp handle_response({:ok, %{status: 200, body: body}}, _ref) do
    case rows(body) do
      nil -> {:error, {:unexpected_body, body}}
      [] -> {:ok, false}
      [_ | _] -> {:ok, true}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}, _ref),
    do: {:error, {:http_status, status, body}}

  defp handle_response({:error, exception}, _ref), do: {:error, exception}

  # The list may arrive bare or wrapped; accept both rather than guess, since
  # the envelope is not fixed until intake ships this.
  defp rows(body) when is_list(body), do: body
  defp rows(%{"data" => rows}) when is_list(rows), do: rows
  defp rows(%{"responses" => rows}) when is_list(rows), do: rows
  defp rows(_body), do: nil

  defp config do
    raw = Application.get_env(:scheduling, Scheduling.Compliance) || []

    %{
      base_url: Keyword.get(raw, :base_url, "http://localhost:3001/api/v1"),
      api_key: Keyword.get(raw, :api_key),
      http_timeout_ms: Keyword.get(raw, :http_timeout_ms, 5_000)
    }
  end
end
