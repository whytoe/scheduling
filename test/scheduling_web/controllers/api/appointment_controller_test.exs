defmodule SchedulingWeb.Api.AppointmentControllerTest do
  @moduledoc """
  The booking API, driven through the router with real tokens.

  The error-mapping tests are the substantive ones. The distinction a client
  acts on is retry-or-don't, so each engine error's status code is asserted
  individually rather than lumped into "it returns an error".

  `async: false` — pointing `Scheduling.Auth` at the fake provider writes
  application env, which is global.
  """
  use SchedulingWeb.ConnCase, async: false

  import Scheduling.OidcProvider

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Patients.Patient
  alias Scheduling.Repo

  @start ~U[2026-09-07 09:00:00Z]

  setup :setup_oidc_provider

  defp patient_fixture, do: Repo.insert!(Patient.changeset(%Patient{}, %{name: "Booking API"}))

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp office_fixture(capability_ids, capacity \\ 1) do
    {:ok, office} =
      Offices.create_office(%{
        "name" => "Room #{System.unique_integer([:positive])}",
        "intake_capacity" => capacity,
        "capability_ids" => capability_ids
      })

    office
  end

  defp service_fixture(capability_ids, minutes \\ 20) do
    {:ok, service} =
      Catalog.create_diagnosis(%{
        "name" => "Svc #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "duration_minutes" => minutes,
        "capability_ids" => capability_ids
      })

    service
  end

  defp slots_for(office, count, minutes \\ 20, from \\ @start) do
    for i <- 0..(count - 1) do
      starts_at = DateTime.add(from, i * minutes * 60, :second)

      Repo.insert!(%Slot{
        office_id: office.id,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, minutes * 60, :second),
        status: :open
      })
    end
  end

  # A bookable world: one capability, one room, slots, and a service.
  defp bookable do
    cap = capability_fixture("CT scanner")
    office = office_fixture([cap.id])
    slots = slots_for(office, 8)
    service = service_fixture([cap.id])
    %{cap: cap, office: office, slots: slots, service: service}
  end

  defp operator(ctx), do: with_bearer(ctx.conn, access_token(ctx))

  defp as_role(ctx, roles) do
    with_bearer(build_conn(), access_token(ctx, %{}, roles: roles))
  end

  defp book_body(overrides) do
    %{"appointment" => Map.merge(%{"from" => DateTime.to_iso8601(@start)}, overrides)}
  end

  describe "POST /api/v1/appointments" do
    test "books and returns the appointment", ctx do
      w = bookable()
      patient = patient_fixture()

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient.id, "service_code" => w.service.code})
        )

      body = json_response(conn, 201)

      assert body["patient_id"] == patient.id
      assert body["status"] == "booked"
      assert body["binding"] == "committed"
      assert body["office_id"] == w.office.id
      assert body["starts_at"] == DateTime.to_iso8601(@start)
      assert [%{"name" => name}] = body["required_capabilities"]
      assert name == w.cap.name
    end

    test "several eligible offices make it provisional", ctx do
      cap = capability_fixture("Consult room")
      a = office_fixture([cap.id])
      b = office_fixture([cap.id])
      slots_for(a, 4)
      slots_for(b, 4)
      service = service_fixture([cap.id])

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => service.code})
        )

      assert json_response(conn, 201)["binding"] == "provisional"
    end

    test "accepts an explicit capability list instead of a service", ctx do
      w = bookable()

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{
            "patient_id" => patient_fixture().id,
            "required_capability_ids" => [w.cap.id]
          })
        )

      assert json_response(conn, 201)["status"] == "booked"
    end

    test "a 40-minute service reserves two consecutive slots", ctx do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 4)
      service = service_fixture([cap.id], 40)

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => service.code})
        )

      body = json_response(conn, 201)
      assert body["ends_at"] == DateTime.to_iso8601(DateTime.add(@start, 40 * 60, :second))
    end
  end

  describe "error mapping — retry or don't" do
    test "409 no_available_slots when nothing is free in the window", ctx do
      w = bookable()

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          %{
            "appointment" => %{
              "patient_id" => patient_fixture().id,
              "service_code" => w.service.code,
              "from" => DateTime.to_iso8601(~U[2027-01-01 09:00:00Z])
            }
          }
        )

      assert json_response(conn, 409)["error"]["code"] == "no_available_slots"
    end

    test "409 no_available_slots when every slot is already booked", ctx do
      cap = capability_fixture("CT scanner")
      office = office_fixture([cap.id])
      slots_for(office, 1)
      service = service_fixture([cap.id])

      {:ok, _first} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: service.code,
          from: @start
        })

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => service.code})
        )

      assert json_response(conn, 409)["error"]["code"] == "no_available_slots"
    end

    test "422 no_eligible_office when no room can ever serve it", ctx do
      needed = capability_fixture("MRI")
      other = capability_fixture("XRay")
      office = office_fixture([other.id])
      slots_for(office, 4)
      service = service_fixture([needed.id])

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => service.code})
        )

      body = json_response(conn, 422)
      assert body["error"]["code"] == "no_eligible_office"
      # The message has to tell a client not to keep hammering it.
      assert body["error"]["message"] =~ "not help"
    end

    test "422 unknown_service for a code that does not exist", ctx do
      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => "svc_nope"})
        )

      assert json_response(conn, 422)["error"]["code"] == "unknown_service"
    end

    test "422 validation_failed for a patient that does not exist", ctx do
      w = bookable()

      conn =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => 999_999, "service_code" => w.service.code})
        )

      assert json_response(conn, 422)["error"]["code"] == "validation_failed"
    end

    test "422 appointment_cancelled when rescheduling a cancelled appointment", ctx do
      w = bookable()

      {:ok, appointment} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: w.service.code,
          from: @start
        })

      {:ok, cancelled} = Booking.cancel_appointment(appointment)

      conn =
        operator(ctx)
        |> patch(~p"/api/v1/appointments/#{cancelled.id}", %{"appointment" => %{}})

      assert json_response(conn, 422)["error"]["code"] == "appointment_cancelled"
    end

    test "the conflict and rejection codes are disjoint", ctx do
      # A client keying off status code alone must not see the same code under
      # both, or "is this retryable" becomes ambiguous.
      w = bookable()

      retryable =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          %{
            "appointment" => %{
              "patient_id" => patient_fixture().id,
              "service_code" => w.service.code,
              "from" => DateTime.to_iso8601(~U[2027-01-01 09:00:00Z])
            }
          }
        )
        |> json_response(409)

      terminal =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => "svc_nope"})
        )
        |> json_response(422)

      refute retryable["error"]["code"] == terminal["error"]["code"]
    end
  end

  describe "idempotency" do
    test "the same external_ref returns the original, not a second booking", ctx do
      w = bookable()
      patient = patient_fixture()

      body =
        book_body(%{
          "patient_id" => patient.id,
          "service_code" => w.service.code,
          "external_ref" => "booking-4821"
        })

      first = operator(ctx) |> post(~p"/api/v1/appointments", body) |> json_response(201)
      second = operator(ctx) |> post(~p"/api/v1/appointments", body) |> json_response(201)

      assert first["id"] == second["id"]
      assert second["external_ref"] == "booking-4821"
      assert length(Booking.list_appointments()) == 1
    end
  end

  describe "reschedule and cancel" do
    setup ctx do
      w = bookable()

      {:ok, appointment} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: w.service.code,
          from: @start
        })

      Map.merge(ctx, Map.put(w, :appointment, appointment))
    end

    test "PATCH moves the appointment and frees the old slot", ctx do
      [original] = ctx.appointment.slots
      later = DateTime.add(@start, 60 * 60, :second)

      conn =
        operator(ctx)
        |> patch(
          ~p"/api/v1/appointments/#{ctx.appointment.id}",
          %{"appointment" => %{"from" => DateTime.to_iso8601(later)}}
        )

      assert json_response(conn, 200)["starts_at"] == DateTime.to_iso8601(later)
      assert Booking.get_slot!(original.id).status == :open
    end

    test "POST cancel releases the slots", ctx do
      [held] = ctx.appointment.slots

      conn = operator(ctx) |> post(~p"/api/v1/appointments/#{ctx.appointment.id}/cancel")

      assert json_response(conn, 200)["status"] == "cancelled"
      assert Booking.get_slot!(held.id).status == :open
      assert Booking.get_slot!(held.id).appointment_id == nil
    end

    test "cancelling twice is safe", ctx do
      operator(ctx)
      |> post(~p"/api/v1/appointments/#{ctx.appointment.id}/cancel")
      |> json_response(200)

      conn = operator(ctx) |> post(~p"/api/v1/appointments/#{ctx.appointment.id}/cancel")

      assert json_response(conn, 200)["status"] == "cancelled"
    end

    test "404 for an appointment that does not exist", ctx do
      conn = operator(ctx) |> post(~p"/api/v1/appointments/999999/cancel")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v1/appointments" do
    test "lists and filters by patient and status", ctx do
      w = bookable()
      mine = patient_fixture()
      theirs = patient_fixture()

      {:ok, a} =
        Booking.book(%{patient_id: mine.id, service_code: w.service.code, from: @start})

      {:ok, _b} =
        Booking.book(%{patient_id: theirs.id, service_code: w.service.code, from: @start})

      all = operator(ctx) |> get(~p"/api/v1/appointments") |> json_response(200)
      assert length(all) == 2

      filtered =
        operator(ctx)
        |> get(~p"/api/v1/appointments?patient_id=#{mine.id}")
        |> json_response(200)

      assert Enum.map(filtered, & &1["id"]) == [a.id]

      {:ok, _} = Booking.cancel_appointment(a)

      booked =
        operator(ctx) |> get(~p"/api/v1/appointments?status=booked") |> json_response(200)

      refute a.id in Enum.map(booked, & &1["id"])
    end

    test "an unrecognised status is ignored rather than returning nothing", ctx do
      w = bookable()

      {:ok, _} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: w.service.code,
          from: @start
        })

      body =
        operator(ctx) |> get(~p"/api/v1/appointments?status=nonsense") |> json_response(200)

      assert length(body) == 1
    end

    test "GET by id", ctx do
      w = bookable()

      {:ok, appointment} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: w.service.code,
          from: @start
        })

      body =
        operator(ctx) |> get(~p"/api/v1/appointments/#{appointment.id}") |> json_response(200)

      assert body["id"] == appointment.id
    end
  end

  describe "GET /api/v1/slots" do
    test "filters by office, status and time window", ctx do
      w = bookable()
      other = office_fixture([w.cap.id])
      slots_for(other, 2)

      all = operator(ctx) |> get(~p"/api/v1/slots") |> json_response(200)
      assert length(all) == 10

      mine =
        operator(ctx) |> get(~p"/api/v1/slots?office_id=#{w.office.id}") |> json_response(200)

      assert length(mine) == 8
      assert Enum.all?(mine, &(&1["office_id"] == w.office.id))

      windowed =
        operator(ctx)
        |> get(
          ~p"/api/v1/slots?office_id=#{w.office.id}&from=#{DateTime.to_iso8601(DateTime.add(@start, 40 * 60, :second))}"
        )
        |> json_response(200)

      assert length(windowed) == 6
    end

    test "status filter separates booked from open", ctx do
      w = bookable()

      {:ok, _} =
        Booking.book(%{
          patient_id: patient_fixture().id,
          service_code: w.service.code,
          from: @start
        })

      booked = operator(ctx) |> get(~p"/api/v1/slots?status=booked") |> json_response(200)
      open = operator(ctx) |> get(~p"/api/v1/slots?status=open") |> json_response(200)

      assert length(booked) == 1
      assert length(open) == 7
      assert hd(booked)["appointment_id"]
    end
  end

  describe "role gating" do
    test "a viewer may read but not book", ctx do
      w = bookable()

      assert as_role(ctx, ["viewer"]) |> get(~p"/api/v1/appointments") |> json_response(200)
      assert as_role(ctx, ["viewer"]) |> get(~p"/api/v1/slots") |> json_response(200)

      conn =
        as_role(ctx, ["viewer"])
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => w.service.code})
        )

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "a service token may book — this is the integration path", ctx do
      w = bookable()

      conn =
        with_bearer(build_conn(), service_token(ctx))
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{"patient_id" => patient_fixture().id, "service_code" => w.service.code})
        )

      assert json_response(conn, 201)
    end

    test "an unauthenticated request is refused", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/appointments"), 401)
    end
  end

  describe "the data boundary" do
    test "no response carries a service code or clinical label", ctx do
      w = bookable()

      created =
        operator(ctx)
        |> post(
          ~p"/api/v1/appointments",
          book_body(%{
            "patient_id" => patient_fixture().id,
            "service_code" => w.service.code,
            "external_ref" => "ref-1"
          })
        )

      body = json_response(created, 201)

      # The code went in; it must not come back out, and nothing may look up
      # the service name behind it.
      refute Map.has_key?(body, "service_code")
      refute Map.has_key?(body, "diagnosis_id")
      refute Map.has_key?(body, "diagnosis")

      raw = Jason.encode!(body)
      refute raw =~ w.service.code
      refute raw =~ w.service.name

      # What it does carry is equipment.
      assert [%{"name" => cap_name}] = body["required_capabilities"]
      assert cap_name == w.cap.name

      listed = operator(ctx) |> get(~p"/api/v1/appointments") |> json_response(200)
      refute Jason.encode!(listed) =~ w.service.code
      refute Jason.encode!(listed) =~ w.service.name
    end
  end
end
