defmodule Scheduling.PracticesTest do
  @moduledoc """
  Practices exist here for one reason: a location's name is not unique.

  This deployment holds five sites and three are called "Main Office" — one per
  practice — and two of those three have no address. Without the practice name
  an operator choosing between them has nothing to go on at all.

  `async: false` — points `Scheduling.Core` at a Bypass server, which is
  application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Practices

  setup do
    bypass = Bypass.open()
    original_core = Application.get_env(:scheduling, Scheduling.Core)
    original_auth = Application.get_env(:scheduling, Scheduling.Auth)

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "scheduling-svc",
      client_secret: "secret",
      http_timeout_ms: 500
    )

    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "secret"
    )

    start_supervised!({Scheduling.ServiceTokenStub, {:ok, "svc_token"}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass}
  end

  defp stub(bypass, pages) do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/v1/practices", fn conn ->
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

  defp practice(id, overrides \\ %{}) do
    Map.merge(
      %{"id" => id, "name" => "Practice #{id}", "slug" => id, "organizationId" => "org-1"},
      overrides
    )
  end

  defp page(items),
    do: %{"data" => items, "page" => 1, "pageSize" => 100, "total" => length(items)}

  describe "Locations.label/1 — the reason practices are here at all" do
    alias Scheduling.Locations
    alias Scheduling.Locations.Location

    defp location_fixture(core_id, name, core_practice_id) do
      Repo.insert!(
        Location.changeset(%Location{}, %{
          core_location_id: core_id,
          name: name,
          core_practice_id: core_practice_id
        })
      )
    end

    test "distinguishes two sites that share a name", %{bypass: bypass} do
      # The exact production shape: three sites called "Main Office", one per
      # practice, two of them with no address. Without the practice they are
      # indistinguishable.
      stub(bypass, [
        page([
          practice("prac-a", %{"name" => "Avenue D Pediatrics"}),
          practice("prac-b", %{"name" => "Sunshine Pediatrics"})
        ])
      ])

      assert {:ok, _} = Practices.sync_from_core()

      location_fixture("loc-a", "Main Office", "prac-a")
      location_fixture("loc-b", "Main Office", "prac-b")

      labels = Locations.list_locations() |> Enum.map(&Locations.label/1) |> Enum.sort()

      assert labels == ["Avenue D Pediatrics — Main Office", "Sunshine Pediatrics — Main Office"]
    end

    test "falls back to the site name when the practice is not synced yet" do
      # The two syncs are independent on purpose, so this window is real rather
      # than hypothetical. A bare name beats an exception in a render.
      location_fixture("loc-c", "Valley Stream", "prac-unsynced")

      [location] = Locations.list_locations()
      assert Locations.label(location) == "Valley Stream"
    end

    test "falls back to the core id when there is no name either" do
      # Not reachable through the changeset — `name` is required — so this is
      # asserted against a struct. Kept because label/1 takes a struct and a
      # render is the wrong place to discover a nil.
      assert Locations.label(%Location{core_location_id: "loc-d", name: nil}) == "loc-d"
    end
  end

  describe "sync_from_core/1" do
    test "projects practices into the local cache", %{bypass: bypass} do
      stub(bypass, [page([practice("prac-1"), practice("prac-2")])])

      assert {:ok, %{upserted: 2, deactivated: 0, withheld: 0}} = Practices.sync_from_core()

      assert Practices.get_by_core_practice_id("prac-1").name == "Practice prac-1"
      assert Practices.get_by_core_practice_id("prac-1").slug == "prac-1"
      assert Practices.get_by_core_practice_id("prac-1").synced_at
    end

    test "is idempotent — a rename updates rather than duplicates", %{bypass: bypass} do
      stub(bypass, [
        page([practice("prac-1")]),
        page([practice("prac-1", %{"name" => "Renamed"})])
      ])

      assert {:ok, %{upserted: 1}} = Practices.sync_from_core()
      assert {:ok, %{upserted: 1}} = Practices.sync_from_core()

      assert Practices.get_by_core_practice_id("prac-1").name == "Renamed"
      assert length(Practices.list_practices()) == 1
    end

    test "falls back to the id when ac-core sends no name", %{bypass: bypass} do
      # A practice labelled with a cuid is poor, but it is still better than a
      # blank label next to a site called "Main Office".
      stub(bypass, [page([practice("prac-9", %{"name" => nil, "slug" => nil})])])

      assert {:ok, _} = Practices.sync_from_core()
      assert Practices.get_by_core_practice_id("prac-9").name == "prac-9"
    end

    test "an empty response deactivates nothing", %{bypass: bypass} do
      # Same guard and same reasoning as Scheduling.Locations: an empty list
      # cannot be told apart from losing permission to see them, and this
      # deployment has already spent two weeks in exactly that state.
      stub(bypass, [page([practice("prac-1"), practice("prac-2")]), page([])])

      assert {:ok, _} = Practices.sync_from_core()
      assert {:ok, %{deactivated: 0, withheld: 2}} = Practices.sync_from_core()

      assert Practices.get_by_core_practice_id("prac-1").active == true
    end

    test "still deactivates a genuine single removal", %{bypass: bypass} do
      stub(bypass, [
        page([practice("prac-1"), practice("prac-2")]),
        page([practice("prac-1")])
      ])

      assert {:ok, _} = Practices.sync_from_core()
      assert {:ok, %{deactivated: 1, withheld: 0}} = Practices.sync_from_core()

      assert Practices.get_by_core_practice_id("prac-2").active == false
    end

    test "an unreachable registry changes nothing", %{bypass: bypass} do
      stub(bypass, [page([practice("prac-1")])])
      assert {:ok, _} = Practices.sync_from_core()

      Bypass.down(bypass)

      assert {:error, _} = Practices.sync_from_core()
      assert Practices.get_by_core_practice_id("prac-1").active == true
    end
  end
end
