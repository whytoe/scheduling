defmodule Scheduling.Booking.SlotGeneratorTest do
  @moduledoc """
  Slot generation: local wall time to UTC instants, across real DST
  transitions, idempotently, without ever destroying a committed slot.

  The DST cases use **real** 2026 `America/New_York` transitions rather than
  synthetic ones — a fabricated transition would pass against a stub database
  and tell us nothing about the one actually configured.

    * spring forward: 2026-03-08, 02:00–03:00 local never happens
    * fall back:      2026-11-01, 01:00–02:00 local happens twice
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Offices
  alias Scheduling.Repo

  @ny "America/New_York"

  defp office_fixture(timezone \\ @ny) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 1,
        "timezone" => timezone
      })

    office
  end

  defp rule_fixture(office, overrides \\ %{}) do
    {:ok, rule} =
      Booking.create_availability_rule(
        Map.merge(
          %{
            office_id: office.id,
            day_of_week: 1,
            starts_at: ~T[09:00:00],
            ends_at: ~T[17:00:00],
            slot_minutes: 20,
            effective_from: ~D[2026-01-01]
          },
          overrides
        )
      )

    rule
  end

  defp starts_at_utc(office) do
    [office_id: office.id]
    |> Booking.list_slots()
    |> Enum.map(&DateTime.to_iso8601(&1.starts_at))
  end

  describe "plain generation" do
    test "produces one slot per whole slot in the window" do
      office = office_fixture()
      rule_fixture(office)

      # 2026-09-07 is a Monday. 09:00-17:00 at 20 minutes = 24 slots.
      result = Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      assert result.created == 24
      assert result.conflicts == []
      assert length(Booking.list_slots(office_id: office.id)) == 24
    end

    test "slots are contiguous and each is one slot_minutes long" do
      office = office_fixture()
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 20})

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      [a, b, c] = Booking.list_slots(office_id: office.id)

      assert DateTime.compare(a.ends_at, b.starts_at) == :eq
      assert DateTime.compare(b.ends_at, c.starts_at) == :eq
      assert DateTime.diff(a.ends_at, a.starts_at, :minute) == 20
    end

    test "generates nothing on a day the rule does not apply" do
      office = office_fixture()
      rule_fixture(office, %{day_of_week: 1})

      # 2026-09-08 is a Tuesday.
      assert Booking.generate_slots(office, ~D[2026-09-08], ~D[2026-09-08]).created == 0
    end

    test "spans a multi-day range" do
      office = office_fixture()
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      # Two Mondays in the range: 2026-09-07 and 2026-09-14.
      assert Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-20]).created == 2
    end

    test "new slots default to :open" do
      office = office_fixture()
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      assert [%Slot{status: :open}] = Booking.list_slots(office_id: office.id)
    end
  end

  describe "local wall time resolves through the office timezone" do
    test "9am New York is 14:00Z before the March transition and 13:00Z after" do
      # The anchor assertion for the whole design. A rule saying 09:00 must
      # keep meaning nine in the morning locally; if generation stored a fixed
      # offset instead, both of these would land on the same UTC hour.
      office = office_fixture(@ny)
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      # 2026-03-02 and 2026-03-09 are Mondays either side of 2026-03-08.
      Booking.generate_slots(office, ~D[2026-03-02], ~D[2026-03-09])

      assert starts_at_utc(office) == ["2026-03-02T14:00:00Z", "2026-03-09T13:00:00Z"]
    end

    test "an office in another zone generates different instants from the same rule" do
      ny = office_fixture(@ny)
      utc = office_fixture("Etc/UTC")

      for office <- [ny, utc] do
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})
        Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      end

      assert starts_at_utc(ny) == ["2026-09-07T13:00:00Z"]
      assert starts_at_utc(utc) == ["2026-09-07T09:00:00Z"]
    end
  end

  describe "daylight saving" do
    test "skips slots in the spring-forward gap rather than crashing" do
      # 2026-03-08 is a Sunday. 01:00-04:00 local, hourly: 01:00 exists,
      # 02:00 does not (the clock jumps to 03:00), 03:00 exists.
      office = office_fixture(@ny)

      rule_fixture(office, %{
        day_of_week: 7,
        starts_at: ~T[01:00:00],
        ends_at: ~T[04:00:00],
        slot_minutes: 60
      })

      result = Booking.generate_slots(office, ~D[2026-03-08], ~D[2026-03-08])

      assert result.created == 2
      assert result.skipped_gap == 1
      assert starts_at_utc(office) == ["2026-03-08T06:00:00Z", "2026-03-08T07:00:00Z"]
    end

    test "resolves the fall-back ambiguity to the earlier instant, once" do
      # 2026-11-01 is a Sunday. 01:00-02:00 local happens twice — first in EDT
      # (-04:00 => 05:00Z), then in EST (-05:00 => 06:00Z). Generating both
      # would double the room's capacity for that hour.
      office = office_fixture(@ny)

      rule_fixture(office, %{
        day_of_week: 7,
        starts_at: ~T[01:00:00],
        ends_at: ~T[02:00:00],
        slot_minutes: 60
      })

      result = Booking.generate_slots(office, ~D[2026-11-01], ~D[2026-11-01])

      assert result.created == 1
      assert result.skipped_gap == 0
      assert starts_at_utc(office) == ["2026-11-01T05:00:00Z"]
    end

    test "a full day spanning the fall-back transition produces no duplicate instants" do
      office = office_fixture(@ny)

      rule_fixture(office, %{
        day_of_week: 7,
        starts_at: ~T[00:00:00],
        ends_at: ~T[06:00:00],
        slot_minutes: 60
      })

      Booking.generate_slots(office, ~D[2026-11-01], ~D[2026-11-01])
      instants = starts_at_utc(office)

      assert instants == Enum.uniq(instants)
    end
  end

  describe "idempotency" do
    test "running twice creates nothing the second time" do
      office = office_fixture()
      rule_fixture(office)

      first = Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      second = Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      assert first.created == 24
      assert second.created == 0
      assert length(Booking.list_slots(office_id: office.id)) == 24
    end

    test "a booked slot survives regeneration untouched" do
      # The property that matters most: a regeneration that dropped this would
      # cancel an appointment with nothing to show for it.
      office = office_fixture()
      rule_fixture(office)
      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      [slot | _] = Booking.list_slots(office_id: office.id)
      {:ok, booked} = slot |> Ecto.Changeset.change(status: :booked) |> Repo.update()

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      reloaded = Booking.get_slot!(booked.id)
      assert reloaded.status == :booked
      assert DateTime.compare(reloaded.starts_at, booked.starts_at) == :eq
    end

    test "a blocked slot survives regeneration untouched" do
      office = office_fixture()
      rule_fixture(office)
      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      [slot | _] = Booking.list_slots(office_id: office.id)
      {:ok, blocked} = Booking.block_slot(slot)

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      assert Booking.get_slot!(blocked.id).status == :blocked
    end

    test "the unique index rejects a second slot at the same instant" do
      office = office_fixture()
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})
      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      [existing] = Booking.list_slots(office_id: office.id)

      assert {:error, cs} =
               %Slot{}
               |> Slot.changeset(%{
                 office_id: office.id,
                 starts_at: existing.starts_at,
                 ends_at: existing.ends_at
               })
               |> Repo.insert()

      assert "already has a slot starting at this instant" in errors_on(cs).office_id
    end
  end

  describe "retired rules" do
    test "stop generating new slots but leave the ones already produced" do
      office = office_fixture()

      rule =
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      assert length(Booking.list_slots(office_id: office.id)) == 1

      {:ok, _retired} = Booking.retire_availability_rule(rule, ~D[2026-09-07])

      # A later Monday now generates nothing...
      assert Booking.generate_slots(office, ~D[2026-09-14], ~D[2026-09-14]).created == 0
      # ...and the slot from before the retirement is still there.
      assert length(Booking.list_slots(office_id: office.id)) == 1
    end
  end

  describe "overlapping rules" do
    test "are reported as conflicts rather than silently double-booking a room" do
      office = office_fixture()

      first =
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[11:00:00], slot_minutes: 60})

      second =
        rule_fixture(office, %{starts_at: ~T[10:00:00], ends_at: ~T[12:00:00], slot_minutes: 60})

      result = Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      # 09:00, 10:00, 11:00 — three distinct instants, with 10:00 claimed twice.
      assert result.created == 3
      assert [conflict] = result.conflicts
      assert conflict.rule_ids == Enum.sort([first.id, second.id])
      assert conflict.office_id == office.id
    end

    test "the lowest rule id wins, deterministically across regenerations" do
      office = office_fixture()

      first =
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      _second =
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})

      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])

      assert [slot] = Booking.list_slots(office_id: office.id)
      assert slot.availability_rule_id == first.id
    end

    test "two offices at the same instant are not a conflict" do
      a = office_fixture("Etc/UTC")
      b = office_fixture("Etc/UTC")

      for office <- [a, b] do
        rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})
      end

      result = Booking.generate_all_slots(~D[2026-09-07], ~D[2026-09-07])

      assert result.created == 2
      assert result.conflicts == []
    end
  end

  describe "blocking" do
    setup do
      office = office_fixture()
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[10:00:00], slot_minutes: 60})
      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      [slot] = Booking.list_slots(office_id: office.id)
      %{slot: slot}
    end

    test "withholds an open slot", %{slot: slot} do
      assert {:ok, blocked} = Booking.block_slot(slot)
      assert blocked.status == :blocked
    end

    test "returns a blocked slot to open", %{slot: slot} do
      {:ok, blocked} = Booking.block_slot(slot)
      assert {:ok, reopened} = Booking.unblock_slot(blocked)
      assert reopened.status == :open
    end

    test "refuses to block a booked slot", %{slot: slot} do
      {:ok, booked} = slot |> Ecto.Changeset.change(status: :booked) |> Repo.update()

      assert {:error, cs} = Booking.block_slot(booked)
      assert "cannot block a booked slot; cancel the appointment first" in errors_on(cs).status
    end

    test "refuses to unblock a booked slot", %{slot: slot} do
      {:ok, booked} = slot |> Ecto.Changeset.change(status: :booked) |> Repo.update()

      assert {:error, cs} = Booking.unblock_slot(booked)
      assert errors_on(cs).status != []
    end
  end

  describe "horizon" do
    test "defaults to 60 days" do
      assert Booking.horizon_days() == 60
    end

    test "generate_horizon/0 fills from today forward" do
      office = office_fixture("Etc/UTC")
      today = Date.utc_today()

      # A rule on today's weekday, effective from today, so the horizon
      # necessarily includes at least one occurrence.
      rule_fixture(office, %{
        day_of_week: Date.day_of_week(today),
        starts_at: ~T[09:00:00],
        ends_at: ~T[10:00:00],
        slot_minutes: 60,
        effective_from: today
      })

      assert Booking.generate_horizon().created >= 1
      assert Booking.list_slots(office_id: office.id) != []
    end
  end

  describe "list_slots/1 filters" do
    setup do
      office = office_fixture("Etc/UTC")
      rule_fixture(office, %{starts_at: ~T[09:00:00], ends_at: ~T[12:00:00], slot_minutes: 60})
      Booking.generate_slots(office, ~D[2026-09-07], ~D[2026-09-07])
      %{office: office}
    end

    test "by status", %{office: office} do
      [first | _] = Booking.list_slots(office_id: office.id)
      {:ok, _} = Booking.block_slot(first)

      assert length(Booking.list_slots(office_id: office.id, status: :open)) == 2
      assert length(Booking.list_slots(office_id: office.id, status: :blocked)) == 1
      assert length(Booking.list_slots(office_id: office.id, status: [:open, :blocked])) == 3
    end

    test "by time window, from inclusive and to exclusive", %{office: office} do
      {:ok, from} = DateTime.new(~D[2026-09-07], ~T[10:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(~D[2026-09-07], ~T[11:00:00], "Etc/UTC")

      assert [slot] = Booking.list_slots(office_id: office.id, from: from, to: to)
      assert DateTime.compare(slot.starts_at, from) == :eq
    end
  end
end
