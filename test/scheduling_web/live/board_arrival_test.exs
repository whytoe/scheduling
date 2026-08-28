defmodule SchedulingWeb.BoardArrivalTest do
  @moduledoc """
  The board's one-shot arrival animation.

  **`async: false` on purpose.** The board broadcasts on a single global topic
  (`Scheduling.Queue.board_topic/0`) and PubSub is not covered by the Ecto
  sandbox, so a concurrent test's `{:board_changed, _}` reaches this LiveView
  too. That reload folds the new patient into `prev_waiting_ids` before this
  test's own broadcast arrives, at which point the card is no longer "new" and
  the highlight is correctly withheld — the test fails while the code is right.

  Running sync means no async test overlaps it. The rest of the board's
  behaviour is covered in `board_live_test.exs`, which stays async because it
  asserts on content rather than on novelty.
  """
  use SchedulingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  defp office_fixture(name, capacity) do
    {:ok, office} =
      Offices.create_office(%{"name" => name, "intake_capacity" => capacity})

    office
  end

  defp waiting_entry(name) do
    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
    {:ok, entry} = Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))
    entry
  end

  test "new sign-ins get the arrival animation; existing cards and first paint do not",
       %{conn: conn} do
    _office = office_fixture("Room A", 3)
    early = waiting_entry("Early Bird")

    {:ok, live, _html} = live(conn, ~p"/board")
    # No arrival animation on the initial paint.
    refute has_element?(live, "#w-#{early.id}.is-arriving")

    # A new patient signs in after mount and the board is notified live.
    late = waiting_entry("Late Arrival")
    Phoenix.PubSub.broadcast(Scheduling.PubSub, Queue.board_topic(), {:board_changed, :arrival})
    render(live)

    # Only the newly-arrived card animates in.
    assert has_element?(live, "#w-#{late.id}.is-arriving")
    refute has_element?(live, "#w-#{early.id}.is-arriving")
  end
end
