defmodule Scheduling.MatchingTest do
  use ExUnit.Case, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Matching
  alias Scheduling.Matching.{Candidate, Result}
  alias Scheduling.Offices.Office

  # Capabilities are compared by name here (no id set), which mirrors loaded
  # structs where the same Capability row appears on both sides.
  defp cap(name), do: %Capability{name: name}

  defp office(id, name, capability_names, intake_capacity) do
    %Office{
      id: id,
      name: name,
      intake_capacity: intake_capacity,
      capabilities: Enum.map(capability_names, &cap/1)
    }
  end

  defp chosen_name(%Result{} = result) do
    case Result.chosen_office(result) do
      nil -> nil
      office -> office.name
    end
  end

  describe "eligible_offices/3 — subset matching" do
    test "includes offices that provide a superset of the required capabilities" do
      general = office(1, "General", ["XRay", "Lab"], 5)
      offices = [general]

      assert [%Office{name: "General"}] =
               Matching.eligible_offices([cap("XRay")], offices)
    end

    test "excludes offices missing a required capability" do
      lab_only = office(1, "Lab Only", ["Lab"], 5)

      assert [] = Matching.eligible_offices([cap("XRay")], [lab_only])
    end

    test "an office providing exactly the required set is eligible" do
      exact = office(1, "Exact", ["XRay", "Lab"], 5)

      assert [%Office{name: "Exact"}] =
               Matching.eligible_offices([cap("XRay"), cap("Lab")], [exact])
    end

    test "no required capabilities makes every office with free capacity eligible" do
      a = office(1, "A", ["XRay"], 1)
      b = office(2, "B", ["Lab"], 1)

      eligible = Matching.eligible_offices([], [a, b])
      assert Enum.map(eligible, & &1.name) == ["A", "B"]
    end

    test "preserves input order" do
      a = office(1, "A", ["XRay"], 1)
      b = office(2, "B", ["XRay"], 1)
      c = office(3, "C", ["XRay"], 1)

      eligible = Matching.eligible_offices([cap("XRay")], [c, a, b])
      assert Enum.map(eligible, & &1.name) == ["C", "A", "B"]
    end
  end

  describe "eligible_offices/3 — capacity exclusion" do
    test "excludes offices whose load equals capacity (no free slots)" do
      full = office(1, "Full", ["XRay"], 2)

      assert [] = Matching.eligible_offices([cap("XRay")], [full], %{1 => 2})
    end

    test "excludes offices loaded beyond capacity" do
      over = office(1, "Over", ["XRay"], 2)

      assert [] = Matching.eligible_offices([cap("XRay")], [over], %{1 => 3})
    end

    test "includes offices with at least one free slot" do
      partial = office(1, "Partial", ["XRay"], 2)

      assert [%Office{name: "Partial"}] =
               Matching.eligible_offices([cap("XRay")], [partial], %{1 => 1})
    end

    test "an office with zero intake_capacity is never eligible" do
      zero = office(1, "Zero", ["XRay"], 0)

      assert [] = Matching.eligible_offices([cap("XRay")], [zero])
    end
  end

  describe "match/3 — best-fit selection" do
    test "prefers the tighter office over a more specialized one" do
      tight = office(1, "General XRay", ["XRay"], 5)
      specialized = office(2, "Imaging Suite", ["XRay", "CT", "MRI"], 5)

      result = Matching.match([cap("XRay")], [specialized, tight])

      assert chosen_name(result) == "General XRay"
      assert result.chosen.surplus == 0
      # The specialized office is still eligible, just not chosen.
      assert Enum.map(result.eligible, & &1.office.name) ==
               ["General XRay", "Imaging Suite"]
    end

    test "falls back to a less-specialized office when no exact fit exists" do
      imaging = office(1, "Imaging Suite", ["XRay", "CT"], 5)
      mega = office(2, "Mega Center", ["XRay", "CT", "MRI", "Lab"], 5)

      result = Matching.match([cap("XRay"), cap("CT")], [mega, imaging])

      assert chosen_name(result) == "Imaging Suite"
      assert result.chosen.surplus == 0
    end

    test "chooses the only office that satisfies the full requirement" do
      a = office(1, "A", ["XRay"], 5)
      b = office(2, "B", ["XRay", "Lab"], 5)

      result = Matching.match([cap("XRay"), cap("Lab")], [a, b])
      assert chosen_name(result) == "B"
    end
  end

  describe "match/3 — tie-breaking" do
    test "breaks surplus ties by most free capacity" do
      roomy = office(1, "Roomy", ["XRay", "CT"], 10)
      cramped = office(2, "Cramped", ["XRay", "Lab"], 10)

      # Both have surplus 1 for [XRay]; Cramped is busier, so Roomy wins.
      result = Matching.match([cap("XRay")], [cramped, roomy], %{2 => 8})

      assert chosen_name(result) == "Roomy"
      assert result.chosen.free_capacity == 10
    end

    test "breaks full ties by input order (stable)" do
      first = office(1, "First", ["XRay", "CT"], 5)
      second = office(2, "Second", ["XRay", "Lab"], 5)

      # Equal surplus (1) and equal free capacity (5): input order wins.
      result = Matching.match([cap("XRay")], [first, second])
      assert chosen_name(result) == "First"

      reversed = Matching.match([cap("XRay")], [second, first])
      assert chosen_name(reversed) == "Second"
    end

    test "free-capacity tie-break uses load, not raw capacity" do
      big = office(1, "Big", ["XRay", "CT"], 10)
      small = office(2, "Small", ["XRay", "Lab"], 4)

      # Big has surplus 1 but is heavily loaded (free 1); Small is idle (free 4).
      result = Matching.match([cap("XRay")], [big, small], %{1 => 9})
      assert chosen_name(result) == "Small"
      assert result.chosen.free_capacity == 4
    end
  end

  describe "match/3 — no eligible office" do
    test "returns chosen: nil when capabilities cannot be satisfied" do
      lab_only = office(1, "Lab Only", ["Lab"], 5)

      result = Matching.match([cap("XRay")], [lab_only])

      assert result.chosen == nil
      assert result.eligible == []
      assert Result.chosen_office(result) == nil
      assert result.rationale =~ "No eligible office"
    end

    test "returns chosen: nil when every capable office is full" do
      a = office(1, "A", ["XRay"], 2)
      b = office(2, "B", ["XRay"], 1)

      result = Matching.match([cap("XRay")], [a, b], %{1 => 2, 2 => 1})

      assert result.chosen == nil
      assert result.rationale =~ "No eligible office"
    end

    test "returns chosen: nil for an empty office list" do
      result = Matching.match([cap("XRay")], [])
      assert result.chosen == nil
      assert result.eligible == []
    end
  end

  describe "match/3 — result shape and rationale" do
    test "eligible candidates are sorted best-fit first" do
      tight = office(1, "Tight", ["XRay"], 5)
      mid = office(2, "Mid", ["XRay", "CT"], 5)
      wide = office(3, "Wide", ["XRay", "CT", "MRI"], 5)

      result = Matching.match([cap("XRay")], [wide, mid, tight])

      assert Enum.map(result.eligible, & &1.office.name) == ["Tight", "Mid", "Wide"]
      assert Enum.map(result.eligible, & &1.surplus) == [0, 1, 2]
    end

    test "preserves the supplied required capabilities" do
      office = office(1, "A", ["XRay", "Lab"], 5)
      required = [cap("XRay"), cap("Lab")]

      result = Matching.match(required, [office])
      assert result.required == required
    end

    test "rationale explains the chosen office" do
      a = office(1, "Clinic A", ["XRay"], 3)

      result = Matching.match([cap("XRay")], [a])
      assert result.rationale =~ "Clinic A"
      assert result.rationale =~ "tightest"
    end

    test "chosen is a Candidate exposing office, surplus, and free capacity" do
      a = office(1, "A", ["XRay", "CT"], 4)

      result = Matching.match([cap("XRay")], [a], %{1 => 1})

      assert %Candidate{surplus: 1, free_capacity: 3} = result.chosen
      assert result.chosen.office.name == "A"
    end
  end
end
