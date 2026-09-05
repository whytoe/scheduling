defmodule Scheduling.Locations.SyncerTest do
  @moduledoc """
  The process that makes per-office scoping real.

  `Scheduling.Locations.sync_from_core/1` was correct and tested from the day
  it was written, and did nothing in production for the same length of time,
  because nothing called it. An empty `locations` table is not a neutral
  state — every office is then unlinked, unlinked offices are visible to
  everyone by design, and the deployment looks identical to a working one
  while scoping nothing. These tests are about the calling, not the syncing.

  `async: false` — they start the real GenServer and mutate application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Locations
  alias Scheduling.Locations.Syncer

  setup do
    bypass = Bypass.open()
    original_core = Application.get_env(:scheduling, Scheduling.Core)
    original_auth = Application.get_env(:scheduling, Scheduling.Auth)
    original_locations = Application.get_env(:scheduling, Scheduling.Locations)

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "scheduling-svc",
      client_secret: "secret",
      http_timeout_ms: 500
    )

    # Core.enabled?/0 also requires Auth.enabled?/0 — the token exchange runs
    # through the shared provider worker.
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "secret"
    )

    start_supervised!({Scheduling.ServiceTokenStub, {:ok, "svc_token"}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
      Application.put_env(:scheduling, Scheduling.Locations, original_locations)
    end)

    %{bypass: bypass}
  end

  defp put_config(pairs) do
    existing = Application.get_env(:scheduling, Scheduling.Locations, [])
    Application.put_env(:scheduling, Scheduling.Locations, Keyword.merge(existing, pairs))
  end

  defp site(id) do
    %{
      "id" => id,
      "practiceId" => "prac-1",
      "name" => "Site #{id}",
      "address" => "1 Example St",
      "timezone" => "America/New_York",
      "active" => true
    }
  end

  defp page(sites) do
    %{"data" => sites, "page" => 1, "pageSize" => 100, "total" => length(sites)}
  end

  # Polls rather than sleeping a fixed time: the pass is asynchronous and the
  # point is that it happens, not when.
  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition was never met")
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end
    end
  end

  describe "child_spec_if_enabled/0" do
    test "is present when core credentials are configured" do
      assert Syncer.child_spec_if_enabled() == Syncer
    end

    test "is absent when switched off" do
      put_config(sync_enabled: false)
      refute Syncer.child_spec_if_enabled()
    end

    test "is absent without core credentials" do
      # The local-dev and test default. There is nothing to sync from.
      Application.put_env(:scheduling, Scheduling.Core, [])
      refute Syncer.child_spec_if_enabled()
    end
  end

  describe "a pass" do
    test "projects sites without anyone asking", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/locations", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(page([site("loc-1"), site("loc-2")])))
      end)

      put_config(sync_initial_delay_ms: 10)
      start_supervised!(Syncer)

      eventually(fn ->
        case Locations.list_locations() do
          [_, _] = locations -> {:ok, locations}
          _ -> :retry
        end
      end)

      assert Locations.get_by_core_location_id("loc-1").name == "Site loc-1"
    end

    test "survives a rejected pass and retries", %{bypass: bypass} do
      # The failure that must not take the board down with it. A crash here
      # would restart the supervisor, and repeated failures would exhaust its
      # restart budget and stop the endpoint — an unreachable registry taking
      # out the whole application.
      #
      # 403 rather than 500 on purpose. Req retries 5xx itself, so a 500 would
      # be absorbed inside a single sync_from_core/1 call and this would assert
      # nothing about the syncer's own retry. 403 is not retried by Req, so the
      # error genuinely reaches the failure branch here — and it is the more
      # realistic failure anyway: a token missing core:organizations:read.
      counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/v1/locations", fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          Plug.Conn.resp(conn, 403, ~s({"error":"insufficient_scope"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(page([site("loc-9")])))
        end
      end)

      put_config(sync_initial_delay_ms: 10, sync_min_retry_ms: 20)
      pid = start_supervised!(Syncer)

      eventually(fn ->
        if Locations.get_by_core_location_id("loc-9"), do: {:ok, :synced}, else: :retry
      end)

      # Same process throughout — it retried rather than being restarted.
      assert Process.alive?(pid)
      assert pid == Process.whereis(Syncer)

      # And the retry was the syncer's own: the first pass was refused, so a
      # second request only exists because it scheduled one.
      assert :counters.get(counter, 1) >= 2
    end

    test "nudge/0 is safe when the syncer is not running" do
      refute Process.whereis(Syncer)
      assert Syncer.nudge() == :ok
    end
  end
end
