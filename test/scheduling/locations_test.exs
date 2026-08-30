defmodule Scheduling.LocationsTest do
  @moduledoc """
  Sites projected from ac-core, and how offices attach to them.

  `async: false` — the sync tests point `Scheduling.Core` at a Bypass server,
  which is application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Locations
  alias Scheduling.Locations.Location
  alias Scheduling.Offices

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:scheduling, Scheduling.Core)

    original_auth = Application.get_env(:scheduling, Scheduling.Auth)

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "scheduling-svc",
      client_secret: "secret",
      http_timeout_ms: 500
    )

    # Core.enabled?/0 also requires Auth.enabled?/0 — the token exchange runs
    # through the shared provider worker.
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "secret"
    )

    start_supervised!({Scheduling.ServiceTokenStub, {:ok, "svc_token"}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass}
  end

  defp stub_locations(bypass, pages) do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/v1/locations", fn conn ->
      :counters.add(counter, 1, 1)
      page = :counters.get(counter, 1)

      body =
        Enum.at(pages, page - 1) ||
          %{"data" => [], "page" => page, "pageSize" => 100, "total" => 0}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp site(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "practiceId" => "prac-1",
        "name" => "Site #{id}",
        "address" => "1 Example St",
        "timezone" => "America/New_York",
        "active" => true
      },
      overrides
    )
  end

  defp office_fixture(attrs \\ %{}) do
    {:ok, office} =
      Offices.create_office(
        Map.merge(
          %{"name" => "Room #{System.unique_integer([:positive])}", "intake_capacity" => 1},
          attrs
        )
      )

    office
  end

  describe "sync_from_core/1" do
    test "projects sites into the local cache", %{bypass: bypass} do
      stub_locations(bypass, [
        %{"data" => [site("loc-1"), site("loc-2")], "page" => 1, "pageSize" => 100, "total" => 2}
      ])

      assert {:ok, %{upserted: 2, deactivated: 0}} = Locations.sync_from_core()

      loc = Locations.get_by_core_location_id("loc-1")
      assert loc.name == "Site loc-1"
      assert loc.timezone == "America/New_York"
      assert loc.core_practice_id == "prac-1"
      assert loc.synced_at
    end

    test "is idempotent — a second run updates rather than duplicates", %{bypass: bypass} do
      stub_locations(bypass, [
        %{"data" => [site("loc-1")], "page" => 1, "pageSize" => 100, "total" => 1},
        %{
          "data" => [site("loc-1", %{"name" => "Renamed"})],
          "page" => 1,
          "pageSize" => 100,
          "total" => 1
        }
      ])

      assert {:ok, %{upserted: 1}} = Locations.sync_from_core()
      assert {:ok, %{upserted: 1}} = Locations.sync_from_core()

      assert length(Locations.list_locations()) == 1
      assert Locations.get_by_core_location_id("loc-1").name == "Renamed"
    end

    test "deactivates a site ac-core stopped returning, rather than deleting it",
         %{bypass: bypass} do
      # Deleting would orphan any office pointing at it, and a vanished site is
      # more often a scope change than a decision to erase history.
      stub_locations(bypass, [
        %{"data" => [site("loc-1"), site("loc-2")], "page" => 1, "pageSize" => 100, "total" => 2},
        %{"data" => [site("loc-1")], "page" => 1, "pageSize" => 100, "total" => 1}
      ])

      assert {:ok, _} = Locations.sync_from_core()
      assert {:ok, %{deactivated: 1}} = Locations.sync_from_core()

      assert Locations.get_by_core_location_id("loc-2").active == false
      assert Locations.get_by_core_location_id("loc-1").active == true
    end

    test "walks pages", %{bypass: bypass} do
      stub_locations(bypass, [
        %{"data" => [site("loc-1")], "page" => 1, "pageSize" => 1, "total" => 2},
        %{"data" => [site("loc-2")], "page" => 2, "pageSize" => 1, "total" => 2}
      ])

      assert {:ok, %{upserted: 2, pages: 2}} = Locations.sync_from_core(page_size: 1)
    end

    test "an unreachable registry is an error, and changes nothing", %{bypass: bypass} do
      stub_locations(bypass, [
        %{"data" => [site("loc-1")], "page" => 1, "pageSize" => 100, "total" => 1}
      ])

      assert {:ok, _} = Locations.sync_from_core()
      Bypass.down(bypass)

      assert {:error, _reason} = Locations.sync_from_core()
      # Critically, the earlier site is NOT deactivated by a failed sync.
      assert Locations.get_by_core_location_id("loc-1").active == true
    end

    test "drops a timezone this VM cannot use rather than storing it", %{bypass: bypass} do
      # An unusable timezone is worse than none: an office adopting it would
      # fail at slot generation instead of here.
      stub_locations(bypass, [
        %{
          "data" => [site("loc-1", %{"timezone" => "Mars/Olympus_Mons"})],
          "page" => 1,
          "pageSize" => 100,
          "total" => 1
        }
      ])

      assert {:ok, _} = Locations.sync_from_core()
      assert Locations.get_by_core_location_id("loc-1").timezone == nil
      assert Locations.get_by_core_location_id("loc-1").name == "Site loc-1"
    end

    test "never touches offices", %{bypass: bypass} do
      office = office_fixture(%{"timezone" => "Europe/London"})

      stub_locations(bypass, [
        %{"data" => [site("loc-1")], "page" => 1, "pageSize" => 100, "total" => 1}
      ])

      assert {:ok, _} = Locations.sync_from_core()

      reloaded = Offices.get_office!(office.id)
      assert reloaded.timezone == "Europe/London"
      assert reloaded.location_id == nil
    end
  end

  describe "many offices per site" do
    test "several offices can share one location" do
      {:ok, loc} =
        %Location{}
        |> Location.changeset(%{core_location_id: "loc-1", name: "Site"})
        |> Repo.insert()

      {:ok, a} = Locations.link_office(office_fixture(), loc)
      {:ok, b} = Locations.link_office(office_fixture(), loc)

      assert a.location_id == loc.id
      assert b.location_id == loc.id
    end
  end

  describe "link_office/2 and timezone" do
    setup do
      {:ok, loc} =
        %Location{}
        |> Location.changeset(%{
          core_location_id: "loc-tz",
          name: "Site",
          timezone: "America/New_York"
        })
        |> Repo.insert()

      %{location: loc}
    end

    test "an office still on the default adopts the site's zone", %{location: loc} do
      office = office_fixture()
      assert office.timezone == "Etc/UTC"

      assert {:ok, linked} = Locations.link_office(office, loc)
      assert linked.timezone == "America/New_York"
    end

    test "a deliberately-set timezone is left alone", %{location: loc} do
      # Slot generation reads Office.timezone. Overwriting a set value would
      # move a room's whole calendar by an hour with no audit trail.
      office = office_fixture(%{"timezone" => "Europe/London"})

      assert {:ok, linked} = Locations.link_office(office, loc)
      assert linked.timezone == "Europe/London"
      assert linked.location_id == loc.id
    end

    test "a site with no timezone leaves the office's alone" do
      {:ok, loc} =
        %Location{}
        |> Location.changeset(%{core_location_id: "loc-notz", name: "Site"})
        |> Repo.insert()

      assert {:ok, linked} = Locations.link_office(office_fixture(), loc)
      assert linked.timezone == "Etc/UTC"
    end
  end
end
