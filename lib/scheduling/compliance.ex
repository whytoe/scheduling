defmodule Scheduling.Compliance do
  @moduledoc """
  Compliance verification against the intake-form system.

  At accept time, before assigning a queue entry to an office, we ask intake
  whether the patient has satisfied the forms this encounter requires. Intake
  answers yes or no; a "no" blocks the assignment.

  ## Why this sends references, and computes the verdict here

  Scheduling carries PII but not health data (`docs/data-boundary.md`). Form
  type strings like `"stroke-consent"`, tied to a named patient, are health
  data — and they used to reach the `routing_decisions` rationale, the queue
  metadata and every outbound webhook.

  So an entry carries **opaque compliance references** rather than form names.
  Intake answers one factual question per reference — does this patient have a
  completed response on file — and *scheduling* decides. That split is
  deliberate and was intake's own argument (`docs/intake-compliance-reply.md`):
  the policy about which forms an encounter requires is ours, so the verdict
  should be too. It also keeps the failure explainable — we know which
  requirement is outstanding, which a bare pass/fail could not tell anyone.

  ## When the gate is skipped

  `verify/1` returns `:not_configured` — which the accept flow treats as
  "pass" — when any of:

    * `Scheduling.Compliance.api_key` is unset (the local-dev default), or
    * the entry requires no references, so there is nothing to ask about, or
    * the patient has no `intake_patient_id` to correlate against.

  It fails *open* in those cases by design: the same posture as an
  unconfigured intake, and consistent with the pre-existing behaviour for an
  entry whose diagnosis required no forms.

  Note what this means in practice: an entry created without a service code or
  an explicit reference list requires nothing, and therefore passes. The gate
  constrains encounters whose requirements were resolved at creation. The
  control that keeps *sensitive* encounters out of scheduling altogether is
  the exclusion list on the intake bridge, not this gate — see
  `docs/integrations.md`.
  """

  alias Scheduling.Compliance.Client
  alias Scheduling.Queue.QueueEntry

  @typedoc """
  `:ok` when every required reference has a completed response, `{:blocked,
  unmet}` naming the references that do not, `:not_configured` when there is
  nothing to check (see the module doc), and `{:error, reason}` when intake
  could not be reached — which the accept flow treats as fail-closed.

  `{:blocked, unmet}` carries the references rather than a bare `:blocked` so
  the front desk can be told *which* requirement is outstanding. They stay
  opaque: an operator resolves one to a form name in intakeform, where that is
  appropriate.
  """
  @type result ::
          :ok
          | {:blocked, [String.t()]}
          | :not_configured
          | {:error, term()}

  @doc """
  Asks intake which of the entry's required references the patient has
  satisfied, and blocks on any that are missing.

  The entry's `:patient` must be preloaded (`Scheduling.Queue.get_entry!/1`
  does this).
  """
  @spec verify(QueueEntry.t()) :: result()
  def verify(%QueueEntry{} = entry) do
    with true <- configured?(),
         [_ | _] = refs <- required_refs(entry),
         intake_patient_id when is_binary(intake_patient_id) <- intake_patient_id(entry) do
      check(refs, intake_patient_id)
    else
      # Not configured, nothing required, or no patient to correlate against —
      # nothing to ask intake. See the module doc.
      _ -> :not_configured
    end
  end

  defp check(refs, intake_patient_id) do
    case Client.satisfied_refs(intake_patient_id, refs) do
      {:ok, satisfied} ->
        case Enum.reject(refs, &MapSet.member?(satisfied, &1)) do
          [] -> :ok
          unmet -> {:blocked, unmet}
        end

      # Includes `{:unknown_reference, ref}` — a stale reference is our
      # configuration being wrong, not the patient being non-compliant, and the
      # accept flow renders the two differently.
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Blank entries are dropped rather than sent: an empty string is not a
  # reference, and asking intake about one would earn a 400 that reads as a
  # config fault when the truth is simply that nothing was required.
  defp required_refs(%QueueEntry{required_compliance_refs: refs}) when is_list(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp required_refs(_entry), do: []

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
