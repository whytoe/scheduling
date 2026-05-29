defmodule Scheduling.Matching.Result do
  @moduledoc """
  The outcome of a matching run, structured so a later UI/audit surface can
  explain *why* an office was chosen.

  * `required` — the capabilities the patient needed (as supplied).
  * `eligible` — every eligible `Candidate`, best-fit first.
  * `chosen` — the selected `Candidate`, or `nil` when nothing is eligible.
  * `rationale` — a human-readable explanation of the outcome.
  """

  alias Scheduling.Matching.Candidate

  @type t :: %__MODULE__{
          required: [struct()],
          eligible: [Candidate.t()],
          chosen: Candidate.t() | nil,
          rationale: String.t()
        }

  @enforce_keys [:required, :eligible, :chosen, :rationale]
  defstruct [:required, :eligible, :chosen, :rationale]

  @doc "The chosen office struct, or `nil` when no office was eligible."
  @spec chosen_office(t()) :: struct() | nil
  def chosen_office(%__MODULE__{chosen: nil}), do: nil
  def chosen_office(%__MODULE__{chosen: %Candidate{office: office}}), do: office
end
