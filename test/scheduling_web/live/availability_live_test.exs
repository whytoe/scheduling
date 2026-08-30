defmodule SchedulingWeb.AvailabilityLiveTest do
  @moduledoc """
  The availability-rules admin screen.

  Runs with auth **enabled** (`setup_oidc_provider`) rather than relying on the
  unconfigured-passthrough the other catalog LiveView tests use, because the
  point of this screen's route is that it is admin-gated. Testing it with auth
  off would assert nothing about that.

  `async: false` — the fake provider writes application env.
  """
  use SchedulingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Scheduling.OidcProvider

  alias Scheduling.Auth.Identity
  alias Scheduling.Booking
  alias Scheduling.Offices
  alias SchedulingWeb.Plugs.BrowserAuth

  setup :setup_oidc_provider

  defp sign_in(conn, roles) do
    identity =
      %{
        "sub" => "user-1",
        "email" => "acasey@example.org",
        "sid" => "session-1",
        "name" => "A. Casey",
        "astrum_roles" => roles
      }
      |> Identity.from_claims("scheduling")

    identity = %{identity | expires_at: System.system_time(:second) + 3600}

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(BrowserAuth.identity_key(), Identity.to_session(identity))
  end

  defp admin(conn), do: sign_in(conn, ["admin"])

  defp office_fixture(attrs \\ %{}) do
    {:ok, office} =
      Offices.create_office(
        Map.merge(
          %{
            "name" => "Room #{System.unique_integer([:positive])}",
            "intake_capacity" => 2,
            "timezone" => "America/New_York"
          },
          attrs
        )
      )

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
            effective_from: ~D[2026-09-01]
          },
          overrides
        )
      )

    rule
  end

  describe "access" do
    test "an operator is refused — this is catalog administration", %{conn: conn} do
      conn = conn |> sign_in(["operator"]) |> get(~p"/availability")

      assert html_response(conn, 403) =~ "Not permitted"
    end

    test "an admin gets in", %{conn: conn} do
      {:ok, _live, html} = conn |> admin() |> live(~p"/availability")

      assert html =~ "Availability"
    end
  end

  describe "listing" do
    test "shows rules grouped under their office, with the slot count", %{conn: conn} do
      office = office_fixture(%{"name" => "Imaging Suite"})
      rule_fixture(office)

      {:ok, _live, html} = conn |> admin() |> live(~p"/availability")

      assert html =~ "Imaging Suite"
      assert html =~ "Monday"
      assert html =~ "09:00–17:00"
      # 480-minute window at 20 minutes = 24 whole slots.
      assert html =~ "24"
    end

    test "names the office's timezone, since the window is in local time",
         %{conn: conn} do
      # The single most likely misuse of this screen is entering a window in
      # the operator's own zone, so the office's zone has to be on the page.
      office_fixture(%{"timezone" => "America/New_York"}) |> rule_fixture()

      {:ok, _live, html} = conn |> admin() |> live(~p"/availability")

      assert html =~ "America/New_York"
      assert html =~ "local time"
    end

    test "reads as calm rather than broken when there is nothing yet", %{conn: conn} do
      {:ok, _live, html} = conn |> admin() |> live(~p"/availability")

      assert html =~ "No availability yet"
    end
  end

  describe "creating a rule" do
    test "creates from valid input", %{conn: conn} do
      office = office_fixture()
      {:ok, live, _html} = conn |> admin() |> live(~p"/availability/new")

      live
      |> form("#availability-rule-form",
        availability_rule: %{
          office_id: office.id,
          day_of_week: 3,
          starts_at: "08:00",
          ends_at: "12:00",
          slot_minutes: 30,
          effective_from: "2026-09-01"
        }
      )
      |> render_submit()

      assert_patched(live, ~p"/availability")

      assert [rule] = Booking.list_availability_rules(office_id: office.id)
      assert rule.day_of_week == 3
      assert rule.slot_minutes == 30
      assert render(live) =~ "Wednesday"
    end

    test "surfaces the slot-longer-than-window error rather than failing generically",
         %{conn: conn} do
      # This validation exists because such a rule would silently generate no
      # slots at all. The screen has to say so.
      office = office_fixture()
      {:ok, live, _html} = conn |> admin() |> live(~p"/availability/new")

      html =
        live
        |> form("#availability-rule-form",
          availability_rule: %{
            office_id: office.id,
            day_of_week: 1,
            starts_at: "09:00",
            ends_at: "09:30",
            slot_minutes: 45,
            effective_from: "2026-09-01"
          }
        )
        |> render_submit()

      assert html =~ "would yield no slots"
      assert Booking.list_availability_rules(office_id: office.id) == []
    end
  end

  describe "editing" do
    test "warns that editing rewrites the past", %{conn: conn} do
      rule = office_fixture() |> rule_fixture()

      {:ok, _live, html} = conn |> admin() |> live(~p"/availability/#{rule}/edit")

      assert html =~ "Editing rewrites the past"
      assert html =~ "retire this rule"
    end

    test "the new form carries no such warning", %{conn: conn} do
      {:ok, _live, html} = conn |> admin() |> live(~p"/availability/new")

      refute html =~ "Editing rewrites the past"
    end
  end

  describe "retiring" do
    test "bounds the rule rather than deleting it, and it stays listed",
         %{conn: conn} do
      office = office_fixture(%{"name" => "Room R"})
      # Already in effect, so retiring bounds it at today.
      rule = rule_fixture(office, %{effective_from: ~D[2026-01-01]})

      {:ok, live, _html} = conn |> admin() |> live(~p"/availability")

      live
      |> element("button[aria-label='Retire Room R Monday rule']")
      |> render_click()

      assert render(live) =~ "nothing is cancelled"

      html = live |> element("#retire-rule button", "Retire rule") |> render_click()

      retired = Booking.get_availability_rule!(rule.id)
      refute retired.active
      assert retired.effective_until == Date.utc_today()

      # Still on the page: it explains slots that already exist.
      assert html =~ "Retired"
      assert html =~ "Room R"
    end

    test "a rule that has not started yet is bounded at its own start date",
         %{conn: conn} do
      # The changeset refuses an effective_until before the effective_from, so
      # retiring a future-dated rule "today" would fail validation and the
      # write would silently do nothing.
      office = office_fixture(%{"name" => "Room F"})
      future = Date.add(Date.utc_today(), 30)
      rule = rule_fixture(office, %{effective_from: future})

      {:ok, live, _html} = conn |> admin() |> live(~p"/availability")

      live |> element("button[aria-label='Retire Room F Monday rule']") |> render_click()
      live |> element("#retire-rule button", "Retire rule") |> render_click()

      retired = Booking.get_availability_rule!(rule.id)
      refute retired.active
      assert retired.effective_until == future
    end

    test "an already-retired rule offers no retire action", %{conn: conn} do
      office = office_fixture(%{"name" => "Room Q"})
      rule = rule_fixture(office)
      {:ok, _} = Booking.retire_availability_rule(rule, ~D[2026-09-30])

      {:ok, live, html} = conn |> admin() |> live(~p"/availability")

      assert html =~ "Room Q"
      refute has_element?(live, "button[aria-label='Retire Room Q Monday rule']")
    end
  end

  describe "navigation" do
    test "the tab is admin-only", %{conn: conn} do
      {:ok, _live, admin_html} = conn |> admin() |> live(~p"/board")
      assert admin_html =~ "/availability"

      {:ok, _live, operator_html} = build_conn() |> sign_in(["operator"]) |> live(~p"/board")
      refute operator_html =~ "/availability"
    end
  end
end
