defmodule SchedulingWeb.Api.CapabilitiesPaginationTest do
  @moduledoc """
  End-to-end wiring of keyset pagination on a name-sorted list endpoint (sc-4ey):
  the ?limit/after params, the X-Next-Cursor header, and name ordering preserved
  across pages.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Catalog

  setup do
    s = System.unique_integer([:positive])
    # Zero-padded so string order is unambiguous: name asc.
    names = for i <- 1..5, do: "cap-#{s}-#{String.pad_leading("#{i}", 2, "0")}"
    Enum.each(names, fn n -> {:ok, _} = Catalog.create_capability(%{"name" => n}) end)
    %{names: names}
  end

  test "?limit caps the page and emits X-Next-Cursor; ?after walks in name order", %{
    conn: conn,
    names: names
  } do
    first = get(conn, ~p"/api/v1/capabilities?limit=2")
    page1 = json_response(first, 200) |> Enum.map(& &1["name"]) |> Enum.filter(&(&1 in names))
    # The seeded names are the first five alphabetically among cap-<s>-*; filter
    # to just ours (other tests' capabilities may share the table).
    assert [cursor] = Plug.Conn.get_resp_header(first, "x-next-cursor")

    walked = walk(conn, cursor, names, page1)
    assert walked == names
  end

  # Follow X-Next-Cursor until exhausted, collecting our seeded names in order.
  defp walk(_conn, nil, _names, acc), do: acc

  defp walk(conn, cursor, names, acc) do
    resp = get(build_conn(), ~p"/api/v1/capabilities?limit=2&after=#{cursor}")
    page = json_response(resp, 200) |> Enum.map(& &1["name"]) |> Enum.filter(&(&1 in names))
    next = Plug.Conn.get_resp_header(resp, "x-next-cursor") |> List.first()
    walk(conn, next, names, acc ++ page)
  end
end
