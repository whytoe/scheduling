defmodule SchedulingWeb.RoutingDecisionLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  # Names are suffixed because `capabilities.name` is uniquely indexed and these
  # test files run async. Two tests inserting "MRI" and "XRay" in opposite
  # orders each wait on the other's index lock — a genuine Postgres deadlock
  # (40P01), and the source of a long-running intermittent CI failure.
  defp capability_fixture(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"
    Repo.insert!(Capability.changeset(%Capability{}, %{name: unique}))
  end

  defp office_fixture(name, capacity, capability_ids) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => name,
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    office
  end

  defp waiting_entry(name, required_caps) do
    patient = patient_fixture(name)

    {:ok, entry} =
      Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

    entry
    |> Repo.preload([:patient, :required_capabilities])
    |> QueueEntry.required_capabilities_changeset(required_caps)
    |> Repo.update!()
    |> Repo.preload(:patient)
  end

  describe "Index" do
    test "renders a recorded routing decision with its rationale", %{conn: conn} do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])
      {:ok, _assigned, _result} = Queue.accept(waiting_entry("Jane Doe", [xray]))

      {:ok, live, html} = live(conn, ~p"/decisions")

      assert html =~ "Routing decisions"
      assert html =~ "Jane Doe"
      assert html =~ "XRay"

      # The chosen office and verbatim rationale live in the expandable detail.
      html = live |> element(".audit__row", "Jane Doe") |> render_click()
      assert html =~ "Room A"
      assert html =~ "tightest capability match"
    end

    test "renders the no-eligible-office reason", %{conn: conn} do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      _office = office_fixture("XRay Room", 2, [xray.id])
      {:no_eligible_office, _} = Queue.accept(waiting_entry("Sam Roe", [mri]))

      {:ok, _live, html} = live(conn, ~p"/decisions")

      assert html =~ "Sam Roe"
      assert html =~ "No eligible office"
    end

    test "shows an empty log when no decisions have been made", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/decisions")
      assert html =~ "Routing decisions"
    end
  end
end
