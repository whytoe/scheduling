defmodule Scheduling.HandoffsTest do
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog.Capability
  alias Scheduling.Handoffs
  alias Scheduling.Handoffs.Handoff
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry

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

  defp waiting_entry(required_caps, opts \\ []) do
    patient = patient_fixture(Keyword.get(opts, :patient_name, "Jane Doe"))

    {:ok, entry} =
      Repo.insert(QueueEntry.changeset(%QueueEntry{}, %{patient_id: patient.id}))

    entry
    |> Repo.preload(:required_capabilities)
    |> QueueEntry.required_capabilities_changeset(required_caps)
    |> Repo.update!()
  end

  describe "handoff created + broadcast on accept" do
    test "accept creates a pending handoff for the target office and broadcasts it" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])
      entry = waiting_entry([xray], patient_name: "Jane Doe")

      Handoffs.subscribe_office(office.id)
      Handoffs.subscribe_handoffs()

      {:ok, _assigned, _result} = Queue.accept(entry)

      # Scoped to the target office and on the board-wide topic.
      assert_receive {:handoff_created, %Handoff{} = scoped}
      assert_receive {:handoff_created, %Handoff{} = board}
      assert scoped.id == board.id

      assert scoped.office_id == office.id
      assert scoped.status == :pending
      assert scoped.patient_name == "Jane Doe"
      assert scoped.office_name == "Room A"
      assert scoped.required_capabilities == ["XRay"]
      assert scoped.patient_id == entry.patient_id
      assert scoped.queue_entry_id == entry.id
    end

    test "the target office sees the pending handoff" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])

      {:ok, _assigned, _result} = Queue.accept(waiting_entry([xray]))

      assert [%Handoff{} = handoff] = Handoffs.list_pending_for_office(office.id)
      assert handoff.office_id == office.id
      assert handoff.status == :pending
    end

    test "broadcasts only on the chosen office's scoped topic" do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      target = office_fixture("Target Room", 2, [xray.id])
      other = office_fixture("Other Room", 2, [mri.id])

      Handoffs.subscribe_office(other.id)

      {:ok, assigned, _result} = Queue.accept(waiting_entry([xray]))
      assert assigned.assigned_office_id == target.id

      refute_receive {:handoff_created, _handoff}
      assert Handoffs.list_pending_for_office(other.id) == []
    end

    test "no handoff is created when no office is eligible" do
      xray = capability_fixture("XRay")
      mri = capability_fixture("MRI")
      _office = office_fixture("XRay Room", 2, [xray.id])

      assert {:no_eligible_office, _result} = Queue.accept(waiting_entry([mri]))
      assert Handoffs.list_pending() == []
    end
  end

  describe "acknowledge/2" do
    test "acknowledging clears the handoff and broadcasts" do
      xray = capability_fixture("XRay")
      office = office_fixture("Room A", 2, [xray.id])

      {:ok, _assigned, _result} = Queue.accept(waiting_entry([xray]))
      assert [handoff] = Handoffs.list_pending_for_office(office.id)

      Handoffs.subscribe_handoffs()

      assert {:ok, acknowledged} = Handoffs.acknowledge(handoff, acknowledged_by: "clinical")
      assert acknowledged.status == :acknowledged
      refute is_nil(acknowledged.acknowledged_at)
      assert acknowledged.acknowledged_by == "clinical"

      assert_receive {:handoff_acknowledged, %Handoff{} = acked}
      assert acked.id == handoff.id

      assert Handoffs.list_pending_for_office(office.id) == []
      assert Handoffs.list_pending() == []
    end

    test "rejects acknowledging a handoff that is not pending" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 2, [xray.id])

      {:ok, _assigned, _result} = Queue.accept(waiting_entry([xray]))
      [handoff] = Handoffs.list_pending()

      {:ok, acknowledged} = Handoffs.acknowledge(handoff)

      assert {:error, changeset} = Handoffs.acknowledge(acknowledged)
      assert "must be pending to acknowledge, was acknowledged" in errors_on(changeset).status
    end
  end

  describe "list_pending/0" do
    test "lists every pending handoff oldest first and omits acknowledged ones" do
      xray = capability_fixture("XRay")
      _office = office_fixture("Room A", 5, [xray.id])

      {:ok, _a, _} = Queue.accept(waiting_entry([xray], patient_name: "First"))
      {:ok, _b, _} = Queue.accept(waiting_entry([xray], patient_name: "Second"))

      pending = Handoffs.list_pending()
      assert Enum.map(pending, & &1.patient_name) == ["First", "Second"]

      {:ok, _} = Handoffs.acknowledge(hd(pending))

      assert Enum.map(Handoffs.list_pending(), & &1.patient_name) == ["Second"]
    end
  end
end
