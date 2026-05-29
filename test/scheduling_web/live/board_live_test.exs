defmodule SchedulingWeb.BoardLiveTest do
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
    test "renders the waiting queue with required capabilities and office capacity",
         %{conn: conn} do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 3, [xray.id])
      _entry = waiting_entry("Jane Doe", [xray])

      {:ok, _live, html} = live(conn, ~p"/board")

      assert html =~ "Shared board"
      # Office section: name, capability, and capacity columns.
      assert html =~ "Room A"
      assert html =~ "XRay"
      # Waiting room section: the waiting patient.
      assert html =~ "Jane Doe"
      assert html =~ "Waiting room (1)"
    end
  end

  describe "real-time updates" do
    test "updates when a patient is accepted via the context broadcast", %{conn: conn} do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, live, html} = live(conn, ~p"/board")
      assert html =~ "Jane Doe"
      assert html =~ "Waiting room (1)"

      # Accept the patient out-of-band; Queue.accept/1 broadcasts on success.
      {:ok, _assigned, _result} = Queue.accept(Queue.get_entry!(entry.id))

      html = render(live)

      # Patient has left the waiting room, now appears in service, and the
      # office shows load.
      assert html =~ "Waiting room (0)"
      assert html =~ "In service (1)"
      assert html =~ "Jane Doe"
      assert Queue.current_loads() == %{office.id => 1}
    end

    test "re-renders the board on a direct board broadcast", %{conn: conn} do
      _office = office_fixture("Room A", 1, [])

      {:ok, live, _html} = live(conn, ~p"/board")

      # A new patient arrives after mount; a broadcast should refresh the board.
      _entry = waiting_entry("Late Arrival", [])
      Phoenix.PubSub.broadcast(Scheduling.PubSub, Queue.board_topic(), {:board_changed, :arrival})

      html = render(live)
      assert html =~ "Late Arrival"
      assert html =~ "Waiting room (1)"
    end
  end

  describe "completion + re-queue actions" do
    test "completing an in-service patient frees capacity live", %{conn: conn} do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 1, [xray.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      {:ok, live, html} = live(conn, ~p"/board")
      assert html =~ "In service (1)"
      assert html =~ "Jane Doe"
      assert Queue.current_loads() == %{office.id => 1}

      html =
        live
        |> element("#board-active button", "Complete")
        |> render_click()

      assert html =~ "In service (0)"
      assert html =~ "capacity freed"
      assert Queue.current_loads() == %{}

      reloaded = Repo.get!(QueueEntry, assigned.id)
      assert reloaded.status == :completed
    end

    test "re-queuing an in-service patient returns them to the waiting room", %{conn: conn} do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 1, [xray.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, _assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      {:ok, live, _html} = live(conn, ~p"/board")

      html =
        live
        |> element("#board-active button", "Re-queue")
        |> render_click()

      assert html =~ "In service (0)"
      assert html =~ "Waiting room (1)"
      assert Queue.current_loads() == %{}
      refute office.id in Map.keys(Queue.current_loads())

      reloaded = Repo.get!(QueueEntry, entry.id)
      assert reloaded.status == :waiting
      assert is_nil(reloaded.assigned_office_id)
    end
  end

  describe "incoming-patient handoffs" do
    test "an incoming handoff appears live when a patient is accepted", %{conn: conn} do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, live, html} = live(conn, ~p"/board")
      assert html =~ "Incoming patients (0)"

      # Accept out-of-band; the handoff broadcast should push to the board.
      {:ok, _assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      html = render(live)
      assert html =~ "Incoming patients (1)"
      assert html =~ "Jane Doe"
      assert html =~ "Room A"
    end

    test "acknowledging an incoming handoff clears it live", %{conn: conn} do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])
      entry = waiting_entry("Jane Doe", [xray])

      {:ok, _assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      {:ok, live, html} = live(conn, ~p"/board")
      assert html =~ "Incoming patients (1)"
      assert html =~ "Jane Doe"

      html =
        live
        |> element("#board-incoming button", "Acknowledge")
        |> render_click()

      assert html =~ "Incoming patients (0)"
      assert html =~ "handoff cleared"
    end
  end
end
