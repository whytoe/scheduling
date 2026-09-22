defmodule Scheduling.QueueWaitEstimateTest do
  @moduledoc """
  `Queue.wait_estimate/1` — a patient's 1-based place in the waiting line, in the
  order the matcher dequeues (sc-ckz Phase 1). `estimated_minutes` is always nil
  until throughput is tracked.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry

  defp patient do
    Repo.insert!(
      Patient.changeset(%Patient{}, %{name: "P #{System.unique_integer([:positive])}"})
    )
  end

  defp waiting(attrs \\ %{}) do
    {:ok, entry} = Queue.create_entry(Map.merge(%{"patient_id" => patient().id}, attrs))
    entry
  end

  describe "position" do
    test "numbers waiting entries 1, 2, 3 in dequeue order" do
      a = waiting()
      b = waiting()
      c = waiting()

      assert Queue.wait_estimate(a).position == 1
      assert Queue.wait_estimate(b).position == 2
      assert Queue.wait_estimate(c).position == 3
    end

    test "higher priority jumps the line despite arriving last" do
      first = waiting()
      _second = waiting()
      urgent = waiting(%{"priority" => 10})

      assert Queue.wait_estimate(urgent).position == 1
      assert Queue.wait_estimate(first).position == 2
    end

    test "counts only entries genuinely ahead — a cancelled one no longer blocks" do
      ahead = waiting()
      target = waiting()
      assert Queue.wait_estimate(target).position == 2

      ahead |> QueueEntry.transition_changeset(:cancelled) |> Repo.update!()

      assert Queue.wait_estimate(target).position == 1
    end
  end

  describe "an entry that is not waiting" do
    test "has no position — it is not in line" do
      entry = waiting()
      cancelled = entry |> QueueEntry.transition_changeset(:cancelled) |> Repo.update!()

      assert Queue.wait_estimate(cancelled).position == nil
    end
  end

  test "estimated_minutes is always nil in Phase 1" do
    assert Queue.wait_estimate(waiting()).estimated_minutes == nil
  end
end
