defmodule Scheduling.ComplianceFilterCheckTest do
  @moduledoc """
  The caching behaviour of `Scheduling.Compliance.FilterCheck`, exercised
  against its own instance so the expiry can be driven without waiting.

  What the check *decides* is covered in `Scheduling.ComplianceHttpTest` — this
  file is only about how long a decision is kept and when it is thrown away.
  """
  use ExUnit.Case, async: false

  alias Scheduling.Compliance
  alias Scheduling.Compliance.FilterCheck

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:scheduling, Compliance)

    Application.put_env(:scheduling, Compliance,
      base_url: "http://localhost:#{bypass.port}/api/v1",
      api_key: "ik_test",
      http_timeout_ms: 500
    )

    on_exit(fn -> Application.put_env(:scheduling, Compliance, original) end)

    %{bypass: bypass}
  end

  # An intake that implements the filter: it refuses to resolve a reference it
  # never minted, and answers the control query that follows.
  defp stub_filtering_intake(bypass, test_pid) do
    Bypass.expect(bypass, "GET", "/api/v1/responses", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:asked, conn.query_params["compliance_ref"]})

      conn = Plug.Conn.put_resp_content_type(conn, "application/json")

      case conn.query_params["compliance_ref"] do
        nil -> Plug.Conn.resp(conn, 200, Jason.encode!([]))
        _ -> Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "unknown_reference"}))
      end
    end)
  end

  defp start_check(opts) do
    start_supervised!(
      {FilterCheck,
       Keyword.put(opts, :name, :"filter_check_#{System.unique_integer([:positive])}")}
    )
  end

  test "an answer is established once and then reused", %{bypass: bypass} do
    stub_filtering_intake(bypass, self())
    check = start_check(ttl_s: 60)

    assert FilterCheck.verify(check) == :ok
    assert FilterCheck.verify(check) == :ok

    assert_receive {:asked, probe_ref}
    assert probe_ref =~ ~r/^cref_/
    # The control query for the same probe, then nothing further.
    assert_receive {:asked, nil}
    refute_receive {:asked, _}, 200
  end

  test "an expired answer is established again rather than assumed", %{bypass: bypass} do
    # A pass that is never rechecked is the same failure one level up: an
    # intake can roll the filter back, and the weaker pass condition (200 with
    # no rows) stops holding the moment intake records its first response.
    stub_filtering_intake(bypass, self())
    check = start_check(ttl_s: 0)

    assert FilterCheck.verify(check) == :ok
    assert FilterCheck.verify(check) == :ok

    assert_receive {:asked, _}
    assert_receive {:asked, nil}
    assert_receive {:asked, _}
    assert_receive {:asked, nil}
  end

  test "invalidating drops the standing answer", %{bypass: bypass} do
    stub_filtering_intake(bypass, self())
    check = start_check(ttl_s: 60)

    assert FilterCheck.verify(check) == :ok
    assert_receive {:asked, _}
    assert_receive {:asked, nil}

    FilterCheck.invalidate(check)

    assert FilterCheck.verify(check) == :ok
    assert_receive {:asked, _}
  end

  test "pointing at a different intake discards the answer", %{bypass: bypass} do
    # A fact established about one deployment says nothing about another.
    stub_filtering_intake(bypass, self())
    check = start_check(ttl_s: 60)

    assert FilterCheck.verify(check) == :ok
    assert_receive {:asked, _}
    assert_receive {:asked, nil}

    other = Bypass.open()
    stub_filtering_intake(other, self())

    Application.put_env(:scheduling, Compliance,
      base_url: "http://localhost:#{other.port}/api/v1",
      api_key: "ik_test",
      http_timeout_ms: 500
    )

    assert FilterCheck.verify(check) == :ok
    assert_receive {:asked, _}
  end

  test "a process that is not running refuses rather than exits" do
    # `Scheduling.Compliance.verify/1` calls this from inside a request. A
    # missing process must fail closed, not take the caller down.
    assert FilterCheck.verify(:filter_check_that_was_never_started) ==
             {:error, :filter_check_not_started}
  end
end
