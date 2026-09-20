defmodule Scheduling.OfficeActiveLocationTest do
  @moduledoc """
  A room at a site ac-core has closed stays on the board and declines patients.

  The sync has always recorded `active: false` faithfully. Nothing read it, so
  the matcher would still choose a room at a closed site and `accept` would put
  a patient in it — the kind of failure that is invisible until somebody walks
  to a locked door.

  Show-and-refuse rather than hide, deliberately. Rooms vanishing from the
  board with no explanation is the failure mode this codebase has produced most
  often; an operator seeing a room they cannot use is recoverable, an operator
  seeing a shorter list is not.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Locations.Location
  alias Scheduling.Matching
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp location_fixture(core_id, active) do
    Repo.insert!(
      Location.changeset(%Location{}, %{
        core_location_id: core_id,
        name: "Site #{core_id}",
        active: active
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

  defp names(offices), do: offices |> Enum.map(& &1.name) |> Enum.sort()

  setup do
    open_site = location_fixture("loc-open", true)
    closed_site = location_fixture("loc-closed", false)

    %{
      open: office_fixture(%{"name" => "Open-room", "location_id" => open_site.id}),
      closed: office_fixture(%{"name" => "Closed-room", "location_id" => closed_site.id}),
      unlinked: office_fixture(%{"name" => "Unlinked-room"})
    }
  end

  describe "list_offices/1 — the display path" do
    test "still shows a room at a closed site" do
      # Show-and-refuse. The operator needs to see why, not watch it disappear.
      assert names(Offices.list_offices()) == ["Closed-room", "Open-room", "Unlinked-room"]
    end
  end

  describe "list_assignable_offices/1 — the assignment path" do
    test "excludes a room at a closed site" do
      assert names(Offices.list_assignable_offices()) == ["Open-room", "Unlinked-room"]
    end

    test "keeps an unlinked room assignable" do
      # A room not yet attached to a site cannot be attributed to one. Refusing
      # to place patients in it would break a working deployment the moment
      # somebody added a room without linking it.
      assert "Unlinked-room" in names(Offices.list_assignable_offices())
    end

    test "still honours location scoping" do
      assert names(Offices.list_assignable_offices(location_ids: ["loc-open"])) ==
               ["Open-room", "Unlinked-room"]
    end

    test "a scope naming only the closed site yields just the unlinked room" do
      assert names(Offices.list_assignable_offices(location_ids: ["loc-closed"])) ==
               ["Unlinked-room"]
    end
  end

  describe "the matcher" do
    setup do
      patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "A Patient"}))
      {:ok, entry} = Queue.create_entry(%{"patient_id" => patient.id})
      %{entry: entry}
    end

    test "will not choose a room at a closed site", %{entry: entry} do
      result = Matching.match_queue_entry(entry, %{}, location_ids: ["loc-closed"])

      # Only the unlinked room is reachable, so that is what it must pick —
      # never Closed-room.
      assert result.chosen.office.name == "Unlinked-room"
    end

    test "accept refuses rather than placing a patient at a closed site", %{entry: entry} do
      # The property that makes this more than a filtered list. Without it an
      # operator accepts a patient into a room nobody is standing in.
      {:ok, _} = Repo.delete(Offices.get_office!(entry_unlinked_id()))

      assert {:no_eligible_office, _result} =
               Queue.accept(Queue.get_entry!(entry.id), location_ids: ["loc-closed"])

      assert Queue.get_entry!(entry.id).status == :waiting
    end
  end

  # The unlinked room is assignable everywhere, so a test that wants "nothing
  # available" has to remove it first.
  defp entry_unlinked_id do
    Offices.list_offices() |> Enum.find(&(&1.name == "Unlinked-room")) |> Map.fetch!(:id)
  end
end
