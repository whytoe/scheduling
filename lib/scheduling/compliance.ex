defmodule Scheduling.Compliance do
  @moduledoc """
  Compliance verification against the intake-form system.

  At accept time, before assigning a queue entry to an office, we ask intake
  whether the patient has satisfied the forms this encounter requires. Intake
  answers yes or no; a "no" blocks the assignment.

  ## Why this only sends a reference

  Scheduling carries PII but not health data (`docs/data-boundary.md`). Form
  type strings like `"stroke-consent"`, tied to a named patient, are health
  data — and they used to reach the `routing_decisions` rationale, the queue
  metadata and every outbound webhook. `docs/integrations.md` warned about
  exactly this leak.

  So the gate now sends an **opaque `compliance_ref`** (supplied by whoever
  created the entry, ultimately from the EMR) plus the patient's
  `intake_patient_id`. Intake resolves which forms that reference implies and
  returns a verdict. Scheduling never learns the form-type names, so it cannot
  leak them.

  ## When the gate is skipped

  `verify/1` returns `:not_configured` — which the accept flow treats as "pass"
  — when either:

    * `Scheduling.Compliance.api_key` is unset (the local-dev default), or
    * the entry carries no `compliance_ref`, so there is nothing to ask about.

  The second case is expected until ac-checkin starts supplying refs. It fails
  *open* by design: the same posture as an unconfigured intake, and consistent
  with the pre-existing behaviour for an entry whose diagnosis required no
  forms.
  """

  alias Scheduling.Compliance.Client
  alias Scheduling.Queue.QueueEntry

  @typedoc """
  `:ok` when intake reports the patient compliant, `:blocked` when it does not,
  `:not_configured` when there is nothing to check (see the module doc), and
  `{:error, reason}` when intake could not be reached — which the accept flow
  treats as fail-closed.
  """
  @type result :: :ok | :blocked | :not_configured | {:error, term()}

  @doc """
  Asks intake whether the entry's patient has satisfied the forms its
  `compliance_ref` implies.

  The entry's `:patient` must be preloaded (`Scheduling.Queue.get_entry!/1`
  does this).
  """
  @spec verify(QueueEntry.t()) :: result()
  def verify(%QueueEntry{} = entry) do
    with true <- configured?(),
         ref when is_binary(ref) and ref != "" <- compliance_ref(entry),
         intake_patient_id when is_binary(intake_patient_id) <- intake_patient_id(entry) do
      check(ref, intake_patient_id)
    else
      # Not configured, no reference to check, or no patient to correlate
      # against — nothing to ask intake. See the module doc.
      _ -> :not_configured
    end
  end

  defp check(compliance_ref, intake_patient_id) do
    case Client.compliance_status(compliance_ref, patient_id: intake_patient_id) do
      {:ok, %{compliant: true}} ->
        :ok

      {:ok, %{compliant: false}} ->
        :blocked

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compliance_ref(%QueueEntry{compliance_ref: ref}), do: ref

  defp intake_patient_id(%QueueEntry{patient: %{intake_patient_id: id}}) when is_binary(id),
    do: id

  defp intake_patient_id(_), do: nil

  defp configured? do
    case Application.get_env(:scheduling, __MODULE__) do
      nil -> false
      cfg -> not is_nil(Keyword.get(cfg, :api_key))
    end
  end
end
