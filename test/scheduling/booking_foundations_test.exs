defmodule Scheduling.BookingFoundationsTest do
  @moduledoc """
  The two fields booking cannot work without: service duration and office
  timezone. See `docs/booking.md`.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Offices

  describe "service duration" do
    test "defaults to 20 minutes so existing catalog rows stay bookable" do
      {:ok, dx} = Catalog.create_diagnosis(%{"name" => "Consult #{unique()}"})
      assert dx.duration_minutes == 20
    end

    test "is settable per service" do
      {:ok, dx} =
        Catalog.create_diagnosis(%{"name" => "Imaging #{unique()}", "duration_minutes" => 40})

      assert dx.duration_minutes == 40
    end

    test "rejects zero — a service occupying no slots cannot be booked" do
      {:error, cs} =
        Catalog.create_diagnosis(%{"name" => "Bad #{unique()}", "duration_minutes" => 0})

      assert "must be greater than 0" in errors_on(cs).duration_minutes
    end

    test "rejects negative" do
      {:error, cs} =
        Catalog.create_diagnosis(%{"name" => "Bad #{unique()}", "duration_minutes" => -10})

      assert errors_on(cs).duration_minutes != []
    end

    test "rejects longer than a day — that is a data-entry slip, not a service" do
      {:error, cs} =
        Catalog.create_diagnosis(%{"name" => "Bad #{unique()}", "duration_minutes" => 1441})

      assert "must be less than or equal to 1440" in errors_on(cs).duration_minutes
    end
  end

  describe "office timezone" do
    test "defaults to UTC" do
      {:ok, office} =
        Offices.create_office(%{"name" => "Room #{unique()}", "intake_capacity" => 1})

      assert office.timezone == "Etc/UTC"
    end

    test "accepts a real IANA zone" do
      {:ok, office} =
        Offices.create_office(%{
          "name" => "Room #{unique()}",
          "intake_capacity" => 1,
          "timezone" => "America/New_York"
        })

      assert office.timezone == "America/New_York"
    end

    test "rejects a zone the configured database does not know" do
      {:error, cs} =
        Offices.create_office(%{
          "name" => "Room #{unique()}",
          "intake_capacity" => 1,
          "timezone" => "Mars/Olympus_Mons"
        })

      assert "is not a known IANA time zone" in errors_on(cs).timezone
    end
  end

  describe "the time zone database is actually wired up" do
    test "converts local wall time to UTC across a DST boundary" do
      # The reason `tz` is a dependency at all. Under Elixir's default
      # UTC-only database both of these would fail; under a broken one they
      # would agree, and a generated calendar would silently drift an hour.
      {:ok, before_dst} = DateTime.new(~D[2026-03-07], ~T[09:00:00], "America/New_York")
      {:ok, after_dst} = DateTime.new(~D[2026-03-14], ~T[09:00:00], "America/New_York")

      assert DateTime.shift_zone!(before_dst, "Etc/UTC").hour == 14
      assert DateTime.shift_zone!(after_dst, "Etc/UTC").hour == 13
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
