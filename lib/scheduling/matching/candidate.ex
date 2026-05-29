defmodule Scheduling.Matching.Candidate do
  @moduledoc """
  An eligible office paired with the metrics that rank it as a match.

  * `surplus` — number of capabilities the office provides beyond those required
    (`|office_caps| - |required_caps|`). Lower is a tighter fit.
  * `free_capacity` — remaining intake slots (`intake_capacity - current_load`).
  """

  @type t :: %__MODULE__{
          office: struct(),
          surplus: non_neg_integer(),
          free_capacity: pos_integer()
        }

  @enforce_keys [:office, :surplus, :free_capacity]
  defstruct [:office, :surplus, :free_capacity]
end
