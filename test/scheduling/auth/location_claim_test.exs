defmodule Scheduling.Auth.LocationClaimTest do
  @moduledoc """
  `LocationClaim.observe/1` settles sc-24q by logging the *raw* `astrum_location`
  claim on a real login — the shape `Identity` throws away — plus whether its
  ids live in the same space as `locations.core_location_id`.
  """
  use Scheduling.DataCase, async: false

  import ExUnit.CaptureLog

  alias Scheduling.Auth
  alias Scheduling.Auth.LocationClaim
  alias Scheduling.Locations.Location

  # The suite runs at :warning; the observation is an :info (normal login
  # traffic, not a problem). The primary level filters before any capture
  # handler sees it, so lift it for these tests only.
  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp observe(claims), do: capture_log(fn -> assert LocationClaim.observe(claims) == :ok end)

  defp seed_location(core_id) do
    Repo.insert!(Location.changeset(%Location{}, %{core_location_id: core_id, name: "Site #{core_id}"}))
  end

  describe "the no-site question (sc-24q #3)" do
    test "an absent claim is reported as absent, not as an empty scope" do
      assert observe(%{"sub" => "u1"}) =~ "absent from the ID token"
    end

    test "an empty list is called out — it is folded into unrestricted today" do
      assert observe(%{"astrum_location" => []}) =~ "present, empty list"
    end

    test "an empty string is distinguished from an absent claim" do
      assert observe(%{"astrum_location" => ""}) =~ "present, empty string"
    end

    test "a JSON null (oidcc's :null) is reported as null" do
      assert observe(%{"astrum_location" => :null}) =~ "present, JSON null"
    end
  end

  describe "the shape question (sc-24q #2)" do
    test "a single id is reported as a single id" do
      log = observe(%{"astrum_location" => "loc_abc"})
      assert log =~ "single id"
      assert log =~ ~s("loc_abc")
    end

    test "a list is reported with its length and values" do
      log = observe(%{"astrum_location" => ["loc_abc", "loc_def"]})
      assert log =~ "list of 2"
      assert log =~ ~s("loc_abc")
    end
  end

  describe "the id-space question (sc-24q's silent short board)" do
    test "matches are counted against locations.core_location_id" do
      seed_location("loc_abc")
      log = observe(%{"astrum_location" => ["loc_abc", "loc_missing"]})
      assert log =~ "1/2 match locations.core_location_id"
    end

    test "no match reads as a different id space, not as a small scope" do
      log = observe(%{"astrum_location" => "loc_from_another_space"})
      assert log =~ "0/1 match locations.core_location_id"
    end
  end

  describe "robustness" do
    test "the configured claim name is honoured" do
      saved = Application.get_env(:scheduling, Auth)
      on_exit(fn -> Application.put_env(:scheduling, Auth, saved) end)
      Application.put_env(:scheduling, Auth, location_claim: "site_ids")

      log = observe(%{"site_ids" => "s1", "astrum_location" => "ignored"})
      assert log =~ "site_ids:"
      assert log =~ ~s("s1")
      refute log =~ "ignored"
    end

    test "a non-map never raises — a diagnostic must not fail a login" do
      assert LocationClaim.observe(nil) == :ok
      assert LocationClaim.observe("nope") == :ok
    end

    test "a non-string in the list is dropped from the match count, not crashed on" do
      seed_location("loc_abc")
      log = observe(%{"astrum_location" => ["loc_abc", 123]})
      # 123 is filtered before the match check; only the one binary id counts.
      assert log =~ "1/1 match locations.core_location_id"
    end
  end
end
