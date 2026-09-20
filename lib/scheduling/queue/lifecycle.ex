defmodule Scheduling.Queue.Lifecycle do
  @moduledoc """
  Which queue-entry status may follow which, and nothing else.

  Transitions were previously asserted one at a time, inside the changeset that
  performed them — `assignment_changeset/2` checked "must be waiting", and
  `completion_changeset/1` checked "must be active". That works while there are
  four statuses and three transitions. It stops working as soon as the same
  question is asked from several places, because the answer lives in whichever
  changeset happens to be running rather than anywhere you can read it.

  So the table is here, declared once, and every transition consults it.

  ## The table

  | From | May become |
  |---|---|
  | `scheduled` | `waiting`, `cancelled`, `no_show` |
  | `waiting` | `assigned`, `cancelled`, `no_show` |
  | `assigned` | `in_service`, `waiting`, `completed`, `discharged_with_followup`, `cancelled`, `no_show` |
  | `in_service` | `completed`, `discharged_with_followup`, `waiting` |
  | `completed`, `discharged_with_followup`, `cancelled`, `no_show` | nothing |

  Four of those are worth justifying, because they are judgements rather than
  mechanics:

    * **`assigned` may become `no_show`.** A patient given a room who never
      arrives is the case no-show reporting exists for. Capacity was held and
      then wasted, which is precisely what wants counting.
    * **`in_service` may not.** They are in the room. "Did not attend" is not a
      statement anyone can make about someone being seen.
    * **`in_service` may not be cancelled either.** Service began; the way out
      is `completed`, or `waiting` if they need something else. Cancelling
      would erase the fact that a clinician's time was spent.
    * **Terminal is terminal.** Nothing leaves `completed`, `cancelled`,
      `no_show` or `discharged_with_followup`. A patient who returns is a new
      entry, and `discharged_with_followup` already creates one. Re-opening an
      entry would make the audit trail say a visit ended and then did not.

  `waiting` appearing as a target from `assigned` and `in_service` is the
  existing requeue path — a patient returning to the queue for a second
  service — not an undo.
  """

  @scheduled_targets [:waiting, :cancelled, :no_show]
  @waiting_targets [:assigned, :cancelled, :no_show]
  @assigned_targets [
    :in_service,
    :waiting,
    :completed,
    :discharged_with_followup,
    :cancelled,
    :no_show
  ]
  @in_service_targets [:completed, :discharged_with_followup, :waiting]

  @transitions %{
    scheduled: @scheduled_targets,
    waiting: @waiting_targets,
    assigned: @assigned_targets,
    in_service: @in_service_targets,
    completed: [],
    discharged_with_followup: [],
    cancelled: [],
    no_show: []
  }

  @terminal for {status, []} <- @transitions, do: status

  @doc "Every status a queue entry may hold."
  @spec statuses() :: [atom()]
  def statuses, do: Map.keys(@transitions)

  @doc """
  Statuses a queue entry can never leave.

  Useful for the question "is this entry finished", which is otherwise written
  as a list of four atoms in several places and drifts.
  """
  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal

  @doc "True when `entry` is in a status it can never leave."
  @spec terminal?(atom()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc "The statuses `from` may become."
  @spec targets(atom()) :: [atom()]
  def targets(from), do: Map.get(@transitions, from, [])

  @doc "True when `from` may become `to`."
  @spec allowed?(atom(), atom()) :: boolean()
  def allowed?(from, to), do: to in targets(from)

  @doc """
  Checks a transition, returning a reason rather than a boolean when refused.

  The reason names both statuses. A caller rejecting a request needs to say
  what was attempted and from where — "invalid transition" on its own sends
  someone to read code to find out what they did.
  """
  @spec check(atom(), atom()) :: :ok | {:error, {:invalid_transition, atom(), atom()}}
  def check(from, to) do
    if allowed?(from, to), do: :ok, else: {:error, {:invalid_transition, from, to}}
  end

  @doc """
  Human-readable explanation of a refused transition, for the API envelope.

  Says what is possible instead, because the next question after "you cannot do
  that" is always "what can I do".
  """
  @spec explain(atom(), atom()) :: String.t()
  def explain(from, to) do
    case targets(from) do
      [] ->
        "A #{from} entry is finished and cannot become #{to}."

      allowed ->
        "A #{from} entry cannot become #{to}. It may become: " <>
          Enum.map_join(allowed, ", ", &to_string/1) <> "."
    end
  end
end
