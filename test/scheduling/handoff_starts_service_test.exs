defmodule Scheduling.HandoffStartsServiceTest do
  @moduledoc """
  Acknowledging a handoff is a clinician taking the patient, so the entry is in
  service.

  Nothing used to say so. `:in_service` was declared on the schema, enumerated
  in the OpenAPI response, given its own badge and made filterable — and no
  code path ever wrote it. `?status=in_service` returned an empty list forever
  and `?status=active` quietly meant `assigned` alone.

  The board looked right the whole time because two LiveViews infer "in
  service" from the acknowledgement *event* rather than from the status. That
  is how it survived: the display was correct while the column it was
  supposedly showing was never written.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Audit
  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp assigned_entry do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2
      })

    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "Handoff Patient"}))
    {:ok, entry} = Queue.create_entry(%{"patient_id" => patient.id})
    {:ok, assigned, _result} = Queue.accept(Queue.get_entry!(entry.id))

    {assigned, office}
  end

  defp handoff_for(entry, office) do
    {:ok, handoff} = Handoffs.create_handoff(Queue.get_entry!(entry.id), office)
    handoff
  end

  defp event_types(entry_id) do
    Audit.list_events(%{})
    |> Enum.filter(&(&1.queue_entry_id == entry_id))
    |> Enum.map(& &1.type)
  end

  describe "acknowledging a handoff" do
    test "puts the entry in service" do
      {entry, office} = assigned_entry()
      handoff = handoff_for(entry, office)

      assert {:ok, _acked} = Handoffs.acknowledge(handoff, acknowledged_by: "dr-who")
      assert Queue.get_entry!(entry.id).status == :in_service
    end

    test "writes an audit row for the transition" do
      # Every other status change writes one; this one used not to exist at all.
      {entry, office} = assigned_entry()
      handoff = handoff_for(entry, office)

      {:ok, _} = Handoffs.acknowledge(handoff, acknowledged_by: "dr-who")

      assert "queue_entry.in_service" in event_types(entry.id)
    end

    test "the entry is now findable as in_service" do
      # The filter that returned an empty list forever.
      {entry, office} = assigned_entry()
      {:ok, _} = Handoffs.acknowledge(handoff_for(entry, office), acknowledged_by: "dr-who")

      in_service =
        Queue.list_active_entries(%{})
        |> Enum.filter(&(&1.status == :in_service))
        |> Enum.map(& &1.id)

      assert entry.id in in_service
    end

    test "still occupies the office's capacity" do
      # in_service is one of QueueEntry.active_statuses/0, so capacity
      # accounting had a branch that never ran. It runs now, and must not
      # double-count or release the slot.
      {entry, office} = assigned_entry()
      assert Queue.current_loads()[office.id] == 1

      {:ok, _} = Handoffs.acknowledge(handoff_for(entry, office), acknowledged_by: "dr-who")

      assert Queue.current_loads()[office.id] == 1
    end

    test "the entry can then be completed" do
      {entry, office} = assigned_entry()
      {:ok, _} = Handoffs.acknowledge(handoff_for(entry, office), acknowledged_by: "dr-who")

      assert {:ok, completed} = Queue.complete(Queue.get_entry!(entry.id))
      assert completed.status == :completed
      assert Map.get(Queue.current_loads(), office.id, 0) == 0
    end
  end

  describe "when the entry cannot start service" do
    test "the acknowledgement fails with it, rather than half-succeeding" do
      # A handoff acknowledged while the entry stays assigned is precisely the
      # state this bug consisted of. Leaving it reachable as a partial success
      # would preserve the thing being fixed.
      {entry, office} = assigned_entry()
      handoff = handoff_for(entry, office)
      {:ok, _} = Queue.complete(Queue.get_entry!(entry.id))

      assert {:error, changeset} = Handoffs.acknowledge(handoff, acknowledged_by: "dr-who")
      assert changeset.errors[:status]

      # And the handoff is still pending — the whole thing rolled back.
      assert Handoffs.get_handoff!(handoff.id).status == :pending
    end
  end
end
