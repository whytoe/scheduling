defmodule SchedulingWeb.QueueLiveTest do
  use SchedulingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo

  defp patient_fixture(name) do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
  end

  defp capability_fixture(name) do
    Repo.insert!(Capability.changeset(%Capability{}, %{name: name}))
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
    |> Repo.preload(:required_capabilities)
    |> QueueEntry.required_capabilities_changeset(required_caps)
    |> Repo.update!()
  end

  describe "Index" do
    test "lists waiting patients with their required capabilities", %{conn: conn} do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])
      _entry = waiting_entry("Jane Doe", [xray])

      {:ok, _live, html} = live(conn, ~p"/queue")

      assert html =~ "Accept queue"
      assert html =~ "Waiting patients"
      assert html =~ "Jane Doe"
      assert html =~ "XRay"
      # The top entry is pre-selected, so the routing preview names its office.
      assert html =~ "Room A"
    end
  end

  describe "accept action" do
    test "assigns the patient to the best-fit office and surfaces the result", %{conn: conn} do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")

      _tight = office_fixture("Tight Room", 2, [xray.id])
      _loose = office_fixture("Loose Room", 2, [xray.id, mri.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, live, _html} = live(conn, ~p"/queue")

      html =
        live
        |> element("button", "Accept")
        |> render_click()

      assert html =~ "Accepted Jane Doe"
      assert html =~ "Tight Room"
      # Patient leaves the waiting list once assigned.
      refute has_element?(live, "#waiting-#{entry.id}")

      reloaded = Repo.get!(QueueEntry, entry.id)
      assert reloaded.status == :assigned
    end

    test "reflects the chosen office's reduced free capacity after accepting", %{conn: conn} do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 1, [xray.id])
      _entry = waiting_entry("Jane Doe", [xray])

      {:ok, live, _html} = live(conn, ~p"/queue")

      assert Scheduling.Queue.current_loads() == %{}

      _html = live |> element("button", "Accept") |> render_click()

      # Live capacity reflects the new in-service assignment.
      assert Scheduling.Queue.current_loads() == %{office.id => 1}
    end

    test "surfaces 'no eligible office' and keeps the patient waiting", %{conn: conn} do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      _office = office_fixture("XRay Room", 2, [xray.id])
      entry = waiting_entry("Jane Doe", [mri])

      {:ok, live, _html} = live(conn, ~p"/queue")

      html = live |> element("button", "Accept") |> render_click()

      assert html =~ "No eligible office"
      # Patient remains in the waiting list.
      assert has_element?(live, "#waiting-#{entry.id}")

      reloaded = Repo.get!(QueueEntry, entry.id)
      assert reloaded.status == :waiting
    end
  end
end
