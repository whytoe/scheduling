defmodule Scheduling.Compliance do
  @moduledoc """
  Compliance verification against the intake-form system.

  At accept time, before assigning a queue entry to an office, we check
  that the patient has a `status=completed AND flagged=false` intake
  response on file for every form type the entry's diagnosis declares
  in its `required_form_types` array. Missing types block the
  assignment.

  When the `Scheduling.Compliance.api_key` config is nil (default in
  local dev), the gate is disabled — `verify/1` always returns `:ok`.
  This keeps the existing scheduling flow working without an intake
  dependency.
  """

  alias Scheduling.Compliance.Client
  alias Scheduling.Queue.QueueEntry

  @typedoc """
  Either `:ok` when every required form is on file, or `{:missing, [type, ...]}`
  listing the form types the patient hasn't satisfied. `:not_configured` is
  returned when the intake API isn't set up (treated as "skip the gate" by
  the accept flow).
  """
  @type result :: :ok | {:missing, [String.t()]} | :not_configured | {:error, term()}

  @doc """
  Verifies that the queue entry's patient has satisfied every required form
  type for their diagnosis. Returns:

    * `:ok` — every required form is satisfied (or the diagnosis requires none)
    * `{:missing, [form_type, ...]}` — the listed form types are missing
    * `:not_configured` — no API key set; accept flow should skip the check
    * `{:error, reason}` — intake API call failed
  """
  @spec verify(QueueEntry.t()) :: result()
  def verify(%QueueEntry{} = entry) do
    case configured?() do
      false -> :not_configured
      true -> do_verify(entry)
    end
  end

  defp do_verify(entry) do
    required_types = required_form_types(entry)

    cond do
      required_types == [] ->
        :ok

      is_nil(intake_patient_id(entry)) ->
        # Diagnosis demands forms but we have nothing to correlate against.
        {:missing, required_types}

      true ->
        check_all(intake_patient_id(entry), required_types)
    end
  end

  defp check_all(intake_patient_id, required_types) do
    Enum.reduce(required_types, {[], nil}, fn type, {missing_acc, err_acc} ->
      case form_type_satisfied?(intake_patient_id, type) do
        :satisfied -> {missing_acc, err_acc}
        :missing -> {[type | missing_acc], err_acc}
        {:error, e} -> {missing_acc, e}
      end
    end)
    |> case do
      {_, err} when not is_nil(err) -> {:error, err}
      {[], _} -> :ok
      {missing, _} -> {:missing, Enum.reverse(missing)}
    end
  end

  defp form_type_satisfied?(intake_patient_id, form_type) do
    # Pass patient_id through to intake's server-side filter — index-direct
    # via their `qr_patient_idx`. The defensive patientId equality check below
    # stays in place (belt-and-suspenders against an intake-side filter bug
    # that returned other patients' rows).
    case Client.list_completed_responses(form_type, patient_id: intake_patient_id) do
      {:ok, responses} ->
        if Enum.any?(responses, fn r ->
             map_get(r, "patientId") == intake_patient_id and
               map_get(r, "flagged") == false
           end) do
          :satisfied
        else
          :missing
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_form_types(%QueueEntry{diagnosis: %{required_form_types: types}})
       when is_list(types),
       do: types

  defp required_form_types(_), do: []

  defp intake_patient_id(%QueueEntry{patient: %{intake_patient_id: id}}) when is_binary(id),
    do: id

  defp intake_patient_id(_), do: nil

  defp configured? do
    case Application.get_env(:scheduling, __MODULE__) do
      nil -> false
      cfg -> not is_nil(Keyword.get(cfg, :api_key))
    end
  end

  # Looks up either a string-keyed or atom-keyed value. CRITICAL: must use
  # `Map.fetch` not `Map.get || Map.get`, because the latter treats `false`
  # as "missing" and falls through — which silently broke the `flagged: false`
  # check (caught by `compliance_http_test.exs`).
  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp map_get(_, _), do: nil
end
