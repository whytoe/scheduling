defmodule Scheduling.Booking.HorizonKeeperTest do
  @moduledoc """
  The keeper's cold start (BK-12).

  It used to be omitted from the supervision tree when no availability rules
  existed, decided once at boot — so adding the **first** rule to a running
  system started nothing, and the admin who created it was told slots would
  generate and got none.

  `async: false` — these start the real GenServer and mutate application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Booking
  alias Scheduling.Booking.HorizonKeeper
  alias Scheduling.Offices

  setup do
    original = Application.get_env(:scheduling, Scheduling.Booking)
    on_exit(fn -> Application.put_env(:scheduling, Scheduling.Booking, original) end)
    :ok
  end

  defp put_config(pairs) do
    existing = Application.get_env(:scheduling, Scheduling.Booking, [])
    Application.put_env(:scheduling, Scheduling.Booking, Keyword.merge(existing, pairs))
  end

  defp office_fixture do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 1
      })

    office
  end

  defp rule_fixture(office) do
    {:ok, rule} =
      Booking.create_availability_rule(%{
        office_id: office.id,
        day_of_week: Date.day_of_week(Date.utc_today()),
        starts_at: ~T[09:00:00],
        ends_at: ~T[11:00:00],
        slot_minutes: 60,
        effective_from: Date.utc_today()
      })

    rule
  end

  describe "child_spec_if_enabled/0" do
    test "is present even when there are no availability rules at all" do
      # The whole point of BK-12. Previously this returned nil on an empty
      # system, so the first rule someone created started nothing.
      put_config(horizon_keeper_enabled: true)

      assert Booking.list_availability_rules() == []
      assert HorizonKeeper.child_spec_if_enabled() == HorizonKeeper
    end

    test "is absent when switched off" do
      put_config(horizon_keeper_enabled: false)
      refute HorizonKeeper.child_spec_if_enabled()
    end

    test "is on by default" do
      Application.put_env(:scheduling, Scheduling.Booking, [])
      assert HorizonKeeper.enabled?()
    end

    test "is off in the test environment, so nothing queries outside the sandbox" do
      # Guards the config that keeps every other test deterministic.
      refute HorizonKeeper.enabled?()
    end
  end

  describe "running" do
    setup do
      # The keeper queries from its own process, so it needs the sandbox
      # connection shared with it.
      Ecto.Adapters.SQL.Sandbox.mode(Scheduling.Repo, {:shared, self()})
      :ok
    end

    test "generates on boot for a system that already has rules" do
      office = office_fixture()
      rule_fixture(office)

      start_supervised!(HorizonKeeper)
      # handle_continue runs before the first call is answered.
      _ = :sys.get_state(HorizonKeeper)

      assert Booking.list_slots(office_id: office.id) != []
    end

    test "a rule added while it is already running produces slots on a nudge" do
      # The case that was previously a dead end: the process exists on an empty
      # system, so there is something to nudge when the first rule appears.
      start_supervised!(HorizonKeeper)
      _ = :sys.get_state(HorizonKeeper)

      office = office_fixture()
      rule_fixture(office)
      assert Booking.list_slots(office_id: office.id) == []

      HorizonKeeper.nudge()
      _ = :sys.get_state(HorizonKeeper)

      assert Booking.list_slots(office_id: office.id) != []
    end

    test "nudging repeatedly does not leave a pile of timers behind" do
      # Without cancelling, every nudge leaves the old timer running *and* adds
      # another, so each round doubles: the keeper generates more and more
      # often for the life of the process, growing every time anyone edits a
      # rule.
      #
      # Orphaned timers cannot be inspected from outside — there is no "how
      # many timers are pending" API — so the only way to observe the leak is
      # to run a short interval, let them fire, and count. Without the fix the
      # count compounds; with it, it is one boot plus one per nudge plus one
      # per elapsed interval.
      put_config(horizon_interval_ms: 40)

      start_supervised!(HorizonKeeper)
      _ = :sys.get_state(HorizonKeeper)

      for _ <- 1..3 do
        HorizonKeeper.nudge()
        _ = :sys.get_state(HorizonKeeper)
      end

      Process.sleep(400)

      %{runs: runs} = :sys.get_state(HorizonKeeper)

      # Ten intervals elapse, so a healthy keeper lands near 1 + 3 + 10.
      # A leaking one doubles per interval and is into the hundreds by now.
      # Measured: a healthy keeper lands at 13 here (1 boot + 3 nudges + ~9
      # elapsed intervals). A leaking one compounds and hits 40+ in the same
      # window. 25 sits clear of both.
      assert runs < 25, "expected a bounded number of passes, got #{runs} — timers are leaking"
    end
  end

  describe "nudge/0 when the keeper is not running" do
    test "is a no-op rather than an error — callers should not have to check" do
      refute Process.whereis(HorizonKeeper)
      assert HorizonKeeper.nudge() == :ok
    end
  end
end
