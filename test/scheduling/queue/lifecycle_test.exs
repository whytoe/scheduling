defmodule Scheduling.Queue.LifecycleTest do
  @moduledoc """
  The transition table, tested as a table.

  These assertions are deliberately about the *rules* rather than about any
  code path that uses them. The rules are the thing that was previously
  scattered across changesets, where you could only discover them by reading
  each one.
  """
  use ExUnit.Case, async: true

  alias Scheduling.Queue.Lifecycle

  describe "the shape of the machine" do
    test "every status is reachable as a target, except the entry point" do
      # A status nothing can reach is dead weight — a state the system can
      # describe but never enter.
      targets = Lifecycle.statuses() |> Enum.flat_map(&Lifecycle.targets/1) |> MapSet.new()
      unreachable = Lifecycle.statuses() |> Enum.reject(&(&1 in targets))

      assert unreachable == [:scheduled],
             "unreachable statuses: #{inspect(unreachable)} — scheduled is the only " <>
               "legitimate one, since an entry is created into it"
    end

    test "terminal statuses are exactly the four that end a visit" do
      assert Enum.sort(Lifecycle.terminal_statuses()) ==
               [:cancelled, :completed, :discharged_with_followup, :no_show]
    end

    test "nothing leaves a terminal status" do
      for status <- Lifecycle.terminal_statuses(), target <- Lifecycle.statuses() do
        refute Lifecycle.allowed?(status, target),
               "#{status} should be terminal but allows #{target}"
      end
    end
  end

  describe "the judgements, not the mechanics" do
    test "an assigned patient who never arrives is a no_show" do
      # Capacity was held and wasted. That is the case the status exists to
      # count.
      assert Lifecycle.allowed?(:assigned, :no_show)
    end

    test "a patient in service cannot be a no_show" do
      # They are in the room. "Did not attend" is not a statement anyone can
      # make about someone being seen.
      refute Lifecycle.allowed?(:in_service, :no_show)
    end

    test "a patient in service cannot be cancelled" do
      # Service began; the way out is completed, or waiting for another
      # service. Cancelling would erase that a clinician's time was spent.
      refute Lifecycle.allowed?(:in_service, :cancelled)
    end

    test "a completed entry cannot be cancelled" do
      refute Lifecycle.allowed?(:completed, :cancelled)
    end

    test "requeue survives — assigned and in_service may return to waiting" do
      assert Lifecycle.allowed?(:assigned, :waiting)
      assert Lifecycle.allowed?(:in_service, :waiting)
    end

    test "a scheduled entry becomes waiting when its slot arrives" do
      assert Lifecycle.allowed?(:scheduled, :waiting)
    end

    test "a scheduled entry cannot be assigned directly" do
      # It has to become waiting first, which keeps the matcher's "pick from
      # waiting" rule true rather than special-cased.
      refute Lifecycle.allowed?(:scheduled, :assigned)
    end
  end

  describe "check/2 and explain/2" do
    test "check returns the pair, so a caller can say what was attempted" do
      assert Lifecycle.check(:waiting, :assigned) == :ok

      assert Lifecycle.check(:completed, :cancelled) ==
               {:error, {:invalid_transition, :completed, :cancelled}}
    end

    test "explain names what is possible instead" do
      message = Lifecycle.explain(:waiting, :completed)

      assert message =~ "cannot become completed"
      assert message =~ "assigned"
    end

    test "explain says finished rather than listing nothing" do
      assert Lifecycle.explain(:completed, :waiting) =~ "finished"
    end
  end
end
