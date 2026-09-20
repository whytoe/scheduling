defmodule SchedulingWeb.PaginationTest do
  use ExUnit.Case, async: true

  alias SchedulingWeb.Pagination

  describe "parse/1" do
    test "defaults limit to 100 when omitted" do
      assert %{limit: 100, after_id: nil} = Pagination.parse(%{})
    end

    test "accepts a valid integer limit" do
      assert %{limit: 25} = Pagination.parse(%{"limit" => "25"})
    end

    test "caps limit at 500" do
      assert %{limit: 500} = Pagination.parse(%{"limit" => "10000"})
    end

    test "falls back to default on garbage limit" do
      assert %{limit: 100} = Pagination.parse(%{"limit" => "abc"})
      assert %{limit: 100} = Pagination.parse(%{"limit" => "-3"})
      assert %{limit: 100} = Pagination.parse(%{"limit" => "0"})
    end

    test "parses a valid after cursor" do
      assert %{after_id: 42} = Pagination.parse(%{"after" => "42"})
    end

    test "drops a garbage after cursor" do
      assert %{after_id: nil} = Pagination.parse(%{"after" => "not_an_int"})
    end
  end

  describe "slice/2" do
    test "returns the page and a next cursor when there's overflow" do
      rows = for i <- 5..1, do: %{id: i}

      # asking for 3, we got 4 (5 4 3 2 1 -> first 5 rows == over-fetched, but
      # this fixture is 5 rows, limit 3 => page = [5,4,3], rest = [2,1])
      {page, next} = Pagination.slice(rows, 3)
      assert Enum.map(page, & &1.id) == [5, 4, 3]
      assert next == 3
    end

    test "returns nil cursor when the page is the last" do
      rows = [%{id: 3}, %{id: 2}]
      {page, next} = Pagination.slice(rows, 5)
      assert Enum.map(page, & &1.id) == [3, 2]
      assert next == nil
    end

    test "handles an empty result set" do
      assert {[], nil} = Pagination.slice([], 10)
    end
  end

  describe "put_next_cursor/2" do
    test "no header when cursor is nil" do
      conn = Plug.Test.conn(:get, "/")
      conn = Pagination.put_next_cursor(conn, nil)
      assert Plug.Conn.get_resp_header(conn, "x-next-cursor") == []
    end

    test "stamps the X-Next-Cursor header when present" do
      conn = Plug.Test.conn(:get, "/")
      conn = Pagination.put_next_cursor(conn, 17)
      assert Plug.Conn.get_resp_header(conn, "x-next-cursor") == ["17"]
    end
  end
end
