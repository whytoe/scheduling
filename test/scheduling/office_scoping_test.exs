defmodule Scheduling.OfficeScopingTest do
  @moduledoc """
  Per-office access: an operator granted particular ac-core locations sees and
  routes to the rooms at those sites only.

  Two properties matter more than the rest, and both are asserted directly
  rather than left to inspection:

    * **The matcher cannot choose an office outside the scope.** Filtering the
      board alone would only hide things — `accept` would still place a
      patient in a room the operator cannot see, in front of staff with no
      business with them.
    * **Absent scope means unrestricted, never nothing.** A claim the provider
      does not populate must not lock every operator out of every office. That
      is the failure `astrum_roles` nearly produced, and it is the reason this
      defaults permissive.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Scope
  alias Scheduling.Locations.Location
  alias Scheduling.Matching
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  @site_a "loc_aaa"
  @site_b "loc_bbb"

  defp location_fixture(core_id) do
    Repo.insert!(
      Location.changeset(%Location{}, %{
        core_location_id: core_id,
        name: "Site #{core_id}"
      })
    )
  end

  defp office_fixture(attrs) do
    {:ok, office} =
      Offices.create_office(
        Map.merge(
          %{"name" => "Room #{System.unique_integer([:positive])}", "intake_capacity" => 5},
          attrs
        )
      )

    office
  end

  defp identity(location_ids, roles \\ ["operator"]) do
    %Identity{subject: "u1", type: :user, roles: roles, location_ids: location_ids}
  end

  defp names(offices), do: offices |> Enum.map(& &1.name) |> Enum.sort()

  describe "Offices.list_offices/1" do
    setup do
      a = location_fixture(@site_a)
      b = location_fixture(@site_b)

      %{
        at_a: office_fixture(%{"name" => "A-room", "location_id" => a.id}),
        at_b: office_fixture(%{"name" => "B-room", "location_id" => b.id}),
        unlinked: office_fixture(%{"name" => "Unlinked-room"})
      }
    end

    test "nil returns everything" do
      assert names(Offices.list_offices(location_ids: nil)) ==
               ["A-room", "B-room", "Unlinked-room"]
    end

    test "no opts at all returns everything" do
      assert names(Offices.list_offices()) == ["A-room", "B-room", "Unlinked-room"]
    end

    test "a location id returns that site's rooms" do
      assert "A-room" in names(Offices.list_offices(location_ids: [@site_a]))
      refute "B-room" in names(Offices.list_offices(location_ids: [@site_a]))
    end

    test "an unlinked office is visible to everyone" do
      # A room not yet attached to a site cannot be attributed to one. Dropping
      # it would make it vanish from the board with nothing on screen to
      # explain why.
      assert "Unlinked-room" in names(Offices.list_offices(location_ids: [@site_a]))
    end

    test "an id matching nothing returns only the unlinked rooms" do
      assert names(Offices.list_offices(location_ids: ["loc_nope"])) == ["Unlinked-room"]
    end
  end

  describe "Scope.location_ids/1" do
    test "passes through an operator's locations" do
      assert Scope.location_ids(Scope.for_identity(identity([@site_a]))) == [@site_a]
    end

    test "is nil for an identity with no location claim" do
      assert Scope.location_ids(Scope.for_identity(identity(nil))) == nil
    end

    test "is nil for an admin, who administers every site" do
      # An admin already configures offices, capabilities and availability
      # across the deployment; scoping them to a subset would half-break
      # administration in a way that reads as a bug.
      scope = Scope.for_identity(identity([@site_a], ["admin"]))

      assert Scope.location_ids(scope) == nil
    end

    test "is nil when there is no scope at all — auth disabled" do
      assert Scope.location_ids(nil) == nil
    end
  end

  describe "the claim itself" do
    test "reads a single value, as ac-core advertises it" do
      identity = Identity.from_claims(%{"sub" => "u", "astrum_location" => @site_a})

      assert identity.location_ids == [@site_a]
    end

    test "reads a list, for someone who works across sites" do
      identity = Identity.from_claims(%{"sub" => "u", "astrum_location" => [@site_a, @site_b]})

      assert identity.location_ids == [@site_a, @site_b]
    end

    test "an absent claim is unscoped" do
      assert Identity.from_claims(%{"sub" => "u"}).location_ids == nil
    end

    test "an empty claim is unscoped, not empty-allow-list" do
      # Indistinguishable from a provider that does not populate the claim for
      # this user. Reading it as "no sites" would revoke everything from
      # someone who had access yesterday.
      assert Identity.from_claims(%{"sub" => "u", "astrum_location" => []}).location_ids == nil
      assert Identity.from_claims(%{"sub" => "u", "astrum_location" => ""}).location_ids == nil
    end

    test "survives the session round-trip" do
      # Dropping it here would silently widen a scoped operator to every office
      # on their next request — the one direction this must never fail in.
      identity = identity([@site_a])

      assert identity
             |> Identity.to_session()
             |> Identity.from_session()
             |> Map.get(:location_ids) == [@site_a]
    end

    test "an unscoped identity round-trips as unscoped" do
      assert identity(nil)
             |> Identity.to_session()
             |> Identity.from_session()
             |> Map.get(:location_ids) == nil
    end
  end

  describe "the matcher will not reach outside the scope" do
    setup do
      a = location_fixture(@site_a)
      b = location_fixture(@site_b)

      office_fixture(%{"name" => "A-room", "location_id" => a.id})
      office_fixture(%{"name" => "B-room", "location_id" => b.id})

      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Scoped Patient"}))
      {:ok, entry} = Queue.create_entry(%{"patient_id" => patient.id})

      %{entry: entry}
    end

    test "chooses only from the permitted site", %{entry: entry} do
      result = Matching.match_queue_entry(entry, %{}, location_ids: [@site_a])

      assert result.chosen.office.name == "A-room"
    end

    test "finds nothing when the only eligible room is elsewhere", %{entry: entry} do
      result = Matching.match_queue_entry(entry, %{}, location_ids: ["loc_nope"])

      assert result.chosen == nil
    end

    test "accept refuses rather than assigning outside the scope", %{entry: entry} do
      # The property that makes this access control instead of a display
      # filter. Without it an operator accepts a patient into a room they
      # cannot see and cannot undo.
      assert {:no_eligible_office, _result} =
               Queue.accept(Queue.get_entry!(entry.id), location_ids: ["loc_nope"])

      assert Queue.get_entry!(entry.id).status == :waiting
    end

    test "accept assigns normally within the scope", %{entry: entry} do
      assert {:ok, assigned, _result} =
               Queue.accept(Queue.get_entry!(entry.id), location_ids: [@site_a])

      assert assigned.assigned_office.name == "A-room"
    end

    test "accept with no scope reaches every office", %{entry: entry} do
      assert {:ok, assigned, _result} = Queue.accept(Queue.get_entry!(entry.id))
      assert assigned.assigned_office.name in ["A-room", "B-room"]
    end
  end
end
