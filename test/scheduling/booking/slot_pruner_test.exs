defmodule Scheduling.Booking.SlotPrunerTest do
  @moduledoc """
  Pruning removes slots the rules no longer justify.

  The tests that matter are the ones asserting what it *refuses* to remove. A
  predicate slightly wrong here deletes booked slots, which cancels somebody's
  appointment with no record and no message — which is exactly why BK-2 left
  this out rather than shipping it half-done.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Booking.SlotPruner
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient

  # A Monday.
  @monday ~D[2026-09-07]
  @from @monday
  @to Date.add(@monday, 6)

  defp office_fixture(capability_ids \\ []) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2,
        "capability_ids" => capability_ids
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
            ends_at: ~T[11:00:00],
            slot_minutes: 60,
            effective_from: @monday
          },
          overrides
        )
      )

    rule
  end

  defp generate(office), do: Booking.generate_slots(Offices.get_office!(office.id), @from, @to)

  defp prune(office, opts \\ []),
    do: SlotPruner.prune_for_office(Offices.get_office!(office.id), @from, @to, opts)

  # For tests that retire every rule and then assert the slots go. Under the
  # empty-rules guard that is exactly the case automatic pruning refuses, so
  # the intent has to be explicit — which is the guard working.
  defp prune_closed(office), do: prune(office, allow_empty: true)

  defp starts(office) do
    [office_id: office.id]
    |> Booking.list_slots()
    |> Enum.map(&DateTime.to_iso8601(&1.starts_at))
    |> Enum.sort()
  end

  describe "removing what the rules no longer justify" do
    test "a shortened window drops the slots outside it" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)

      assert starts(office) == ["2026-09-07T09:00:00Z", "2026-09-07T10:00:00Z"]

      {:ok, _} = Booking.update_availability_rule(rule, %{ends_at: ~T[10:00:00]})

      assert %{deleted: 1} = prune(office)
      assert starts(office) == ["2026-09-07T09:00:00Z"]
    end

    test "a retired rule's slots go" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      assert length(starts(office)) == 2

      {:ok, _} = Booking.retire_availability_rule(rule, @monday)

      assert %{deleted: 2} = prune_closed(office)
      assert starts(office) == []
    end

    test "leaves slots the rules still justify" do
      office = office_fixture()
      rule_fixture(office)
      generate(office)

      assert %{deleted: 0} = prune(office)
      assert length(starts(office)) == 2
    end

    test "is idempotent" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      {:ok, _} = Booking.retire_availability_rule(rule, @monday)

      assert %{deleted: 2} = prune_closed(office)
      assert %{deleted: 0} = prune_closed(office)
    end

    test "does not touch another office's slots" do
      a = office_fixture()
      b = office_fixture()
      rule_a = rule_fixture(a)
      rule_fixture(b)
      generate(a)
      generate(b)

      {:ok, _} = Booking.retire_availability_rule(rule_a, @monday)

      assert %{deleted: 2} = prune_closed(a)
      assert length(starts(b)) == 2
    end
  end

  describe "what it refuses to remove" do
    setup do
      cap = Catalog.create_capability(%{"name" => "CT-#{System.unique_integer([:positive])}"})
      {:ok, cap} = cap
      office = office_fixture([cap.id])
      rule = rule_fixture(office)
      generate(office)

      %{cap: cap, office: office, rule: rule}
    end

    test "a booked slot survives, even though the rules no longer produce it", ctx do
      # The assertion this whole module exists for. Deleting this slot would
      # cancel an appointment with no record and no message.
      {:ok, service} =
        Catalog.create_diagnosis(%{
          "name" => "Svc #{System.unique_integer([:positive])}",
          "code" => "svc_#{System.unique_integer([:positive])}",
          "duration_minutes" => 60,
          "capability_ids" => [ctx.cap.id]
        })

      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Booked"}))

      {:ok, appointment} =
        Booking.book(%{
          patient_id: patient.id,
          service_code: service.code,
          from: ~U[2026-09-07 09:00:00Z]
        })

      [booked_slot] = appointment.slots

      # Retire the rule entirely: nothing here is justified any more.
      {:ok, _} = Booking.retire_availability_rule(ctx.rule, @monday)

      assert %{deleted: 1, protected: 1} = prune_closed(ctx.office)

      surviving = Booking.get_slot!(booked_slot.id)
      assert surviving.status == :booked
      assert surviving.appointment_id == appointment.id
      assert Booking.get_appointment!(appointment.id).status == :booked
    end

    test "a blocked slot survives — it was withheld deliberately", ctx do
      [first | _] = Booking.list_slots(office_id: ctx.office.id)
      {:ok, _} = Booking.block_slot(first)

      {:ok, _} = Booking.retire_availability_rule(ctx.rule, @monday)

      assert %{deleted: 1, protected: 1} = prune_closed(ctx.office)
      assert Booking.get_slot!(first.id).status == :blocked
    end

    test "a slot carrying an appointment_id survives even if its status drifted", ctx do
      # The second guard. Redundant while book/1 writes status and
      # appointment_id together, and load-bearing the moment anything does not.
      [first | _] = Booking.list_slots(office_id: ctx.office.id)
      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Drift"}))

      appointment =
        Repo.insert!(%Booking.Appointment{
          patient_id: patient.id,
          binding: :committed,
          status: :booked
        })

      Repo.update_all(
        from(s in Slot, where: s.id == ^first.id),
        set: [appointment_id: appointment.id, status: :open]
      )

      {:ok, _} = Booking.retire_availability_rule(ctx.rule, @monday)

      prune_closed(ctx.office)

      assert Booking.get_slot!(first.id).appointment_id == appointment.id
    end
  end

  describe "generation and pruning agree" do
    test "pruning then regenerating restores exactly what the rules describe" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      before = starts(office)

      {:ok, _} = Booking.retire_availability_rule(rule, @monday)
      assert %{deleted: 2} = prune_closed(office)

      # Reinstate the same pattern; the calendar should come back identical.
      rule_fixture(office)
      generate(office)

      assert starts(office) == before
    end

    test "prune deletes nothing immediately after a generation" do
      # If these two disagreed, the keeper would churn: create, delete,
      # create, on every run.
      office = office_fixture()
      rule_fixture(office)
      generate(office)

      assert %{deleted: 0} = prune(office)
    end
  end

  describe "the empty-rules guard" do
    test "refuses to prune an office whose rules produce nothing at all" do
      # "The rules justify nothing" and "we failed to read the rules" produce
      # the same empty set. Without this, one transient bad read would delete
      # every open slot in the horizon on the next keeper tick — and since
      # pruning now runs after every generation, that is a live hazard rather
      # than a theoretical one.
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      assert length(starts(office)) == 2

      # Simulate the rules vanishing.
      {:ok, _} = Booking.retire_availability_rule(rule, @monday)

      assert %{deleted: 0, skipped: 2} = prune(office)
      assert length(starts(office)) == 2
    end

    test "allow_empty: true clears them deliberately" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      {:ok, _} = Booking.retire_availability_rule(rule, @monday)

      assert %{deleted: 2} =
               SlotPruner.prune_for_office(
                 Offices.get_office!(office.id),
                 @from,
                 @to,
                 allow_empty: true
               )

      assert starts(office) == []
    end

    test "still prunes normally when some rules remain" do
      # The guard is about *no* candidates, not fewer. A shortened window is
      # still pruned, because the rules were clearly readable.
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)

      {:ok, _} = Booking.update_availability_rule(rule, %{ends_at: ~T[10:00:00]})

      assert %{deleted: 1, skipped: 0} = prune(office)
      assert starts(office) == ["2026-09-07T09:00:00Z"]
    end

    test "a booked slot is safe even under allow_empty" do
      office = office_fixture()
      rule = rule_fixture(office)
      generate(office)
      [first | _] = Booking.list_slots(office_id: office.id)
      {:ok, _} = Booking.block_slot(first)
      {:ok, _} = Booking.retire_availability_rule(rule, @monday)

      SlotPruner.prune_for_office(Offices.get_office!(office.id), @from, @to, allow_empty: true)

      assert Booking.get_slot!(first.id).status == :blocked
    end
  end

  describe "enabled?/0" do
    test "defaults to on, because the alternative is silently stale calendars" do
      assert SlotPruner.enabled?()
    end
  end
end
