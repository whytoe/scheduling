defmodule SchedulingWeb.Pagination do
  @moduledoc """
  Cursor pagination helpers shared across the JSON list endpoints.

  Contract:

    * Query params: `?limit=N&after=<id>`.
    * `limit` defaults to 100; max 500. Invalid values fall back to default.
    * `after` is the id of the last row from the previous page. Each list
      endpoint orders by `id desc`; the next page returns rows with `id < after`.
    * The response body stays a raw JSON array (no envelope) to keep the
      convention. The next cursor is returned in an `X-Next-Cursor` response
      header. The header is absent when the listing is exhausted.

  Sort caveat: endpoints whose natural semantics are time-ordered
  (`visit_events.occurred_at`, `routing_decisions.inserted_at`) still
  declare that ordering in their tag descriptions. The cursor walk uses
  id-desc as the tiebreaker; for events inserted out-of-order (e.g.
  backfills) this may interleave timeline pages with insert-order pages.
  Acceptable for v1; sc-s7u may revisit with composite cursors if it
  becomes a real problem.
  """
  import Ecto.Query, only: [where: 3, order_by: 3, limit: 2]

  @default_limit 100
  @max_limit 500

  @doc "Parses `limit` and `after` from query params."
  @spec parse(map()) :: %{limit: pos_integer(), after_id: integer() | nil}
  def parse(params) when is_map(params) do
    %{limit: parse_limit(params), after_id: parse_after(params)}
  end

  @doc """
  Applies the cursor + limit to an Ecto query. The query is also ordered by
  `id desc` so pagination is stable. Asks for `limit + 1` rows so the caller
  can detect whether there's a next page.
  """
  @spec apply(Ecto.Queryable.t(), map()) :: Ecto.Queryable.t()
  def apply(query, %{limit: lim, after_id: nil}) do
    query
    |> order_by([r], desc: r.id)
    |> limit(^(lim + 1))
  end

  def apply(query, %{limit: lim, after_id: cursor}) do
    query
    |> where([r], r.id < ^cursor)
    |> order_by([r], desc: r.id)
    |> limit(^(lim + 1))
  end

  @doc """
  Slices an over-fetched list into the page and the next cursor. Returns
  `{rows_for_page, next_cursor_or_nil}`. The caller serializes `rows_for_page`
  and sets `X-Next-Cursor` from the second element via `put_next_cursor/2`.
  """
  @spec slice(list(struct()), pos_integer()) :: {list(struct()), integer() | nil}
  def slice(rows, limit) when is_list(rows) and is_integer(limit) do
    case Enum.split(rows, limit) do
      {page, []} -> {page, nil}
      {page, _rest} -> {page, page |> List.last() |> Map.fetch!(:id)}
    end
  end

  @doc "Sets the `X-Next-Cursor` response header when a next cursor is present."
  def put_next_cursor(conn, nil), do: conn

  def put_next_cursor(conn, cursor),
    do: Plug.Conn.put_resp_header(conn, "x-next-cursor", to_string(cursor))

  defp parse_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        @default_limit

      v ->
        case Integer.parse(to_string(v)) do
          {n, ""} when n > 0 -> min(n, @max_limit)
          _ -> @default_limit
        end
    end
  end

  defp parse_after(params) do
    case Map.get(params, "after") do
      nil ->
        nil

      v ->
        case Integer.parse(to_string(v)) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end
end
