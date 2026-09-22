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

  ## Keyset cursors for non-id orderings (`keyset/3`)

  The list endpoints that sort by something other than id — catalogs by name,
  visits by `started_at`, the queue by `priority`/`inserted_at` — cannot use the
  id-desc walk above without changing their order. `keyset/3` preserves an
  endpoint's own ordering and encodes an **opaque** cursor from the last row's
  ordering values. The query-param and header contract is identical
  (`?limit=&after=`, `X-Next-Cursor`); the only difference is that `after` is an
  opaque token rather than a bare id, which integrators never needed to parse.
  """
  import Ecto.Query

  alias Scheduling.Repo

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

  @doc """
  Keyset-paginates `query` under an explicit ordering, returning
  `{page_rows, next_cursor}`.

  `order` is the FULL ordering as `[{field, :asc | :desc}, ...]`, whose last
  element must be a unique key (typically `:id`) so the walk is total and
  stable. Unlike `apply/2` + `slice/2` — which assume an `id`-desc order —
  this preserves an endpoint's own ordering (name, `started_at`, a
  `priority`/`inserted_at` composite) and encodes an **opaque** cursor from the
  last row's ordering values. Integrators echo the `X-Next-Cursor` header back
  as `after`; they never parse it.

  Sort fields must be non-null (a NULL breaks the keyset comparison the same way
  it breaks `ORDER BY` determinism); every field used here — name, timestamps,
  priority, id — is non-null by schema.

  Does its own `Repo.all`, so associations should be requested via `preload:` in
  the query; the caller serializes the page and sets the header with
  `put_next_cursor/2`.
  """
  @spec keyset(Ecto.Queryable.t(), map(), [{atom(), :asc | :desc}]) ::
          {[struct()], String.t() | nil}
  def keyset(query, params, order) when is_list(order) and order != [] do
    lim = parse_limit(params)

    rows =
      query
      |> order_by(^Enum.map(order, fn {field, dir} -> {dir, field} end))
      |> apply_keyset_cursor(order, decode_cursor(Map.get(params, "after")))
      |> limit(^(lim + 1))
      |> Repo.all()

    case Enum.split(rows, lim) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, encode_cursor(List.last(page), order)}
    end
  end

  defp apply_keyset_cursor(query, _order, nil), do: query

  defp apply_keyset_cursor(query, order, values) when length(order) == length(values) do
    where(query, ^keyset_dynamic(Enum.zip(order, values)))
  end

  # A cursor that does not match the ordering (tampered, or from a different
  # endpoint) is treated as no cursor — the first page — rather than an error.
  defp apply_keyset_cursor(query, _order, _values), do: query

  # A row is strictly "after" the cursor when, at the first ordering field where
  # it differs, it differs in the sort direction — the standard lexicographic
  # keyset predicate, as an OR of (equal-prefix AND strict-here) clauses.
  defp keyset_dynamic(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce(dynamic(false), fn {{{field, dir}, value}, idx}, acc ->
      clause =
        pairs
        |> Enum.take(idx)
        |> Enum.reduce(strict(field, dir, value), fn {{eq_field, _dir}, eq_value}, inner ->
          dynamic([r], field(r, ^eq_field) == ^eq_value and ^inner)
        end)

      dynamic(^acc or ^clause)
    end)
  end

  defp strict(field, :asc, value), do: dynamic([r], field(r, ^field) > ^value)
  defp strict(field, :desc, value), do: dynamic([r], field(r, ^field) < ^value)

  # Cursor = base64url(JSON list of the row's ordering values). DateTimes are
  # tagged so they round-trip back to structs the query can bind, not strings.
  defp encode_cursor(row, order) do
    order
    |> Enum.map(fn {field, _dir} -> encode_value(Map.fetch!(row, field)) end)
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_value(%DateTime{} = dt), do: ["dt", DateTime.to_iso8601(dt)]
  defp encode_value(other), do: other

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, values} when is_list(values) <- Jason.decode(json) do
      Enum.map(values, &decode_value/1)
    else
      _ -> nil
    end
  end

  defp decode_value(["dt", iso]) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> iso
    end
  end

  defp decode_value(other), do: other

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
