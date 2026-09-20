defmodule SchedulingWeb.Api.QueueEntryEndingsTest do
  @moduledoc """
  The `cancel` and `no_show` endpoints, and what they say when refused.

  A refusal has to name what the entry *can* become. A client told only
  "invalid" has to read our code to find out what it did wrong, and an
  integrator cannot do that.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias Scheduling.Repo

  defp entry_fixture do
    patient = Repo.insert!(Patient.changeset(%Patient{}, %{name: "API Ending"}))
    {:ok, entry} = Queue.create_entry(%{"patient_id" => patient.id})
    entry
  end

  defp office_fixture do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => 2
      })

    office
  end

  describe "POST /queue_entries/:id/cancel" do
    test "ends the entry", %{conn: conn} do
      entry = entry_fixture()

      conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/cancel", reason: "called ahead")

      assert json_response(conn, 200)["status"] == "cancelled"
    end

    test "404s for an entry that does not exist", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/queue_entries/999999/cancel", %{})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "refuses a finished entry, and says it is finished", %{conn: conn} do
      entry = entry_fixture()
      {:ok, _} = Queue.cancel(entry)

      conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/cancel", %{})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "validation_failed"
      assert [message] = body["error"]["details"]["fields"]["status"]
      assert message =~ "finished"
    end
  end

  describe "POST /queue_entries/:id/no_show" do
    test "ends a waiting entry", %{conn: conn} do
      entry = entry_fixture()

      conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/no_show", %{})

      assert json_response(conn, 200)["status"] == "no_show"
    end

    test "works from assigned, and frees the room", %{conn: conn} do
      office_fixture()
      entry = entry_fixture()
      {:ok, assigned, _} = Queue.accept(Queue.get_entry!(entry.id))

      conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/no_show", %{})

      assert json_response(conn, 200)["status"] == "no_show"
      assert Map.get(Queue.current_loads(), assigned.assigned_office_id, 0) == 0
    end
  end

  describe "a refusal names the alternatives" do
    test "so an integrator can act on it without reading our source", %{conn: conn} do
      entry = entry_fixture()
      {:ok, _} = Queue.no_show(entry)

      conn = post(conn, ~p"/api/v1/queue_entries/#{entry.id}/cancel", %{})
      [message] = json_response(conn, 422)["error"]["details"]["fields"]["status"]

      # A no_show entry is terminal, so there is nothing to offer — but it must
      # still say which status it was in rather than only which was refused.
      assert message =~ "no_show"
      assert message =~ "cancelled"
    end
  end
end
