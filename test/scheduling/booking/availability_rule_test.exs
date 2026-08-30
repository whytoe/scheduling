defmodule Scheduling.Booking.AvailabilityRuleTest do
  @moduledoc """
  Availability rules — the recurring patterns slot generation expands.

  Times here are the office's **local wall time**; nothing in this module
  resolves an instant. That happens at generation, and the DST correctness it
  depends on is covered in `Scheduling.BookingFoundationsTest`.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Offices

  defp office_fixture do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 1
      })

    office
  end

  defp valid_attrs(office, overrides \\ %{}) do
    Map.merge(
      %{
        office_id: office.id,
        day_of_week: 1,
        starts_at: ~T[09:00:00],
        ends_at: ~T[17:00:00],
        slot_minutes: 20,
        effective_from: ~D[2026-09-01]
      },
      overrides
    )
  end

  describe "creating a rule" do
    test "accepts a well-formed weekly window" do
      office = office_fixture()
      assert {:ok, rule} = Booking.create_availability_rule(valid_attrs(office))

      assert rule.day_of_week == 1
      assert rule.slot_minutes == 20
      assert rule.active
      assert rule.office.id == office.id
    end

    test "requires an office that exists" do
      office = office_fixture()

      assert {:error, cs} =
               Booking.create_availability_rule(valid_attrs(office, %{office_id: 999_999}))

      assert cs.errors[:office] || cs.errors[:office_id]
    end

    test "rejects a day outside 1..7" do
      office = office_fixture()

      for day <- [0, 8, -1] do
        assert {:error, cs} =
                 Booking.create_availability_rule(valid_attrs(office, %{day_of_week: day}))

        assert "is invalid" in errors_on(cs).day_of_week
      end
    end

    test "1 is Monday and 7 is Sunday, matching Date.day_of_week/1" do
      # Generation compares against Date.day_of_week/1 directly, so a
      # mismatched convention here would silently shift every rule by a day.
      assert Date.day_of_week(~D[2026-08-31]) == 1
      assert Date.day_of_week(~D[2026-09-06]) == 7
      assert AvailabilityRule.days() == 1..7
    end
  end

  describe "the window" do
    test "rejects an end at or before the start" do
      office = office_fixture()

      for ends_at <- [~T[09:00:00], ~T[08:00:00]] do
        assert {:error, cs} =
                 Booking.create_availability_rule(valid_attrs(office, %{ends_at: ends_at}))

        assert "must be after the start time" in errors_on(cs).ends_at
      end
    end

    test "rejects a slot longer than the window — it would yield nothing" do
      office = office_fixture()

      attrs =
        valid_attrs(office, %{
          starts_at: ~T[09:00:00],
          ends_at: ~T[09:30:00],
          slot_minutes: 45
        })

      assert {:error, cs} = Booking.create_availability_rule(attrs)
      assert hd(errors_on(cs).slot_minutes) =~ "would yield no slots"
    end

    test "rejects a non-positive or absurd slot length" do
      office = office_fixture()

      for minutes <- [0, -20, 481] do
        assert {:error, cs} =
                 Booking.create_availability_rule(valid_attrs(office, %{slot_minutes: minutes}))

        assert errors_on(cs).slot_minutes != []
      end
    end
  end

  describe "slot_count/1 floors a partial trailing slot" do
    test "an exact fit yields the whole window" do
      rule = %AvailabilityRule{starts_at: ~T[09:00:00], ends_at: ~T[17:00:00], slot_minutes: 20}
      assert AvailabilityRule.window_minutes(rule) == 480
      assert AvailabilityRule.slot_count(rule) == 24
    end

    test "a remainder is dropped rather than offered as a short slot" do
      # 480 minutes at 50 = 9 whole slots and a 30-minute remainder. Offering a
      # tenth short slot would let an appointment overrun the window.
      rule = %AvailabilityRule{starts_at: ~T[09:00:00], ends_at: ~T[17:00:00], slot_minutes: 50}
      assert AvailabilityRule.slot_count(rule) == 9
    end

    test "a window exactly one slot long yields one" do
      rule = %AvailabilityRule{starts_at: ~T[09:00:00], ends_at: ~T[09:20:00], slot_minutes: 20}
      assert AvailabilityRule.slot_count(rule) == 1
    end
  end

  describe "applies_on?/2" do
    setup do
      office = office_fixture()

      {:ok, rule} =
        Booking.create_availability_rule(
          valid_attrs(office, %{day_of_week: 1, effective_from: ~D[2026-09-07]})
        )

      %{rule: rule, office: office}
    end

    test "only on its weekday", %{rule: rule} do
      assert AvailabilityRule.applies_on?(rule, ~D[2026-09-07])
      refute AvailabilityRule.applies_on?(rule, ~D[2026-09-08])
    end

    test "not before it takes effect", %{rule: rule} do
      refute AvailabilityRule.applies_on?(rule, ~D[2026-08-31])
      assert AvailabilityRule.applies_on?(rule, ~D[2026-09-14])
    end

    test "an open-ended rule keeps applying", %{rule: rule} do
      assert rule.effective_until == nil
      assert AvailabilityRule.applies_on?(rule, ~D[2027-09-06])
    end

    test "not after it is retired", %{rule: rule} do
      {:ok, retired} = Booking.retire_availability_rule(rule, ~D[2026-09-21])

      assert AvailabilityRule.applies_on?(%{retired | active: true}, ~D[2026-09-21])
      refute AvailabilityRule.applies_on?(%{retired | active: true}, ~D[2026-09-28])
    end

    test "an inactive rule never applies, whatever the date", %{rule: rule} do
      refute AvailabilityRule.applies_on?(%{rule | active: false}, ~D[2026-09-07])
    end
  end

  describe "effective range" do
    test "rejects an until before the from" do
      office = office_fixture()

      attrs =
        valid_attrs(office, %{effective_from: ~D[2026-09-10], effective_until: ~D[2026-09-01]})

      assert {:error, cs} = Booking.create_availability_rule(attrs)
      assert "must not be before the effective-from date" in errors_on(cs).effective_until
    end

    test "a single-day rule is allowed" do
      office = office_fixture()

      attrs =
        valid_attrs(office, %{effective_from: ~D[2026-09-07], effective_until: ~D[2026-09-07]})

      assert {:ok, _rule} = Booking.create_availability_rule(attrs)
    end
  end

  describe "rules_in_force/2" do
    test "returns only the office's active rules that apply that day" do
      office = office_fixture()
      other = office_fixture()

      {:ok, monday} = Booking.create_availability_rule(valid_attrs(office, %{day_of_week: 1}))
      {:ok, _tuesday} = Booking.create_availability_rule(valid_attrs(office, %{day_of_week: 2}))
      {:ok, _elsewhere} = Booking.create_availability_rule(valid_attrs(other, %{day_of_week: 1}))

      {:ok, evening} =
        Booking.create_availability_rule(
          valid_attrs(office, %{day_of_week: 1, starts_at: ~T[18:00:00], ends_at: ~T[20:00:00]})
        )

      {:ok, _retired} = Booking.retire_availability_rule(evening, ~D[2026-09-01])

      in_force = Booking.rules_in_force(office.id, ~D[2026-09-07])

      assert Enum.map(in_force, & &1.id) == [monday.id]
    end
  end

  describe "retiring" do
    test "bounds the rule instead of deleting it, so old slots stay explicable" do
      office = office_fixture()
      {:ok, rule} = Booking.create_availability_rule(valid_attrs(office))

      assert {:ok, retired} = Booking.retire_availability_rule(rule, ~D[2026-09-30])

      assert retired.effective_until == ~D[2026-09-30]
      refute retired.active
      assert Booking.get_availability_rule!(rule.id).id == rule.id
    end
  end
end
