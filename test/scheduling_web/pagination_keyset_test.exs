defmodule SchedulingWeb.PaginationKeysetTest do
  @moduledoc "keyset/3 — opaque composite-cursor pagination that preserves an endpoint's own ordering (sc-4ey)."
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Catalog.Capability
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue
  alias SchedulingWeb.Pagination

  defp cap(name) do
    {:ok, c} = Catalog.create_capability(%{"name" => name})
    c
  end

  describe "keyset/3 by name asc" do
    setup do
      s = System.unique_integer([:positive])
      names = for l <- ["a", "b", "c", "d", "e"], do: "#{l}#{s}"
      Enum.each(names, &cap/1)
      %{names: names, query: from(x in Capability, where: x.name in ^names)}
    end

    @order [{:name, :asc}, {:id, :asc}]

    test "walks the full listing in order, one page at a time", ctx do
      {p1, c1} = Pagination.keyset(ctx.query, %{"limit" => "2"}, @order)
      assert Enum.map(p1, & &1.name) == Enum.slice(ctx.names, 0, 2)
      assert is_binary(c1)

      {p2, c2} = Pagination.keyset(ctx.query, %{"limit" => "2", "after" => c1}, @order)
      assert Enum.map(p2, & &1.name) == Enum.slice(ctx.names, 2, 2)
      assert is_binary(c2)

      {p3, c3} = Pagination.keyset(ctx.query, %{"limit" => "2", "after" => c2}, @order)
      assert Enum.map(p3, & &1.name) == Enum.slice(ctx.names, 4, 1)
      assert c3 == nil
    end

    test "a full page with nothing after it has no cursor", ctx do
      {page, cursor} = Pagination.keyset(ctx.query, %{"limit" => "5"}, @order)
      assert length(page) == 5
      assert cursor == nil
    end

    test "a tampered cursor is treated as the first page, not an error", ctx do
      {page, _} = Pagination.keyset(ctx.query, %{"after" => "not-a-real-cursor"}, @order)
      assert Enum.map(page, & &1.name) == ctx.names
    end
  end

  describe "keyset/3 composite: priority desc, inserted_at asc, id asc" do
    test "serves highest priority first, arrival order within a priority, across pages" do
      order = [{:priority, :desc}, {:inserted_at, :asc}, {:id, :asc}]

      entries =
        for {name, pri} <- [{"low-1", 0}, {"high-1", 5}, {"low-2", 0}, {"high-2", 5}] do
          p = Repo.insert!(Patient.changeset(%Patient{}, %{name: name}))
          {:ok, e} = Queue.create_entry(%{"patient_id" => p.id, "priority" => pri})
          e
        end

      [low1, high1, low2, high2] = entries
      base = from(e in Scheduling.Queue.QueueEntry, where: e.status == :waiting)

      # Expected total order: the two priority-5s (by id asc), then the two 0s.
      expected = [high1.id, high2.id, low1.id, low2.id]

      {p1, c1} = Pagination.keyset(base, %{"limit" => "2"}, order)
      assert Enum.map(p1, & &1.id) == Enum.slice(expected, 0, 2)

      {p2, c2} = Pagination.keyset(base, %{"limit" => "2", "after" => c1}, order)
      assert Enum.map(p2, & &1.id) == Enum.slice(expected, 2, 2)
      assert c2 == nil
    end
  end
end
