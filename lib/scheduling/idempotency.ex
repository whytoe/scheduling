defmodule Scheduling.Idempotency do
  @moduledoc """
  Makes a retried write safe to send twice.

  An external caller whose request times out cannot tell whether it happened.
  For `POST /api/v1/queue_entries` that is the difference between two queue
  entries for one arrival and none at all — both wrong in front of a waiting
  room. So a caller may send `Idempotency-Key: <something stable>` and repeat
  the request verbatim: the second call returns the **first call's response**,
  including the id of whatever was created.

  `SchedulingWeb.Plugs.Idempotency` is the entry point; this module owns the
  storage and the rules.

  ## What is and is not cached

  `2xx` and `4xx` are cached. Both are decided outcomes: the request was
  processed and this is what it produced, so replaying it is honest.

  **`5xx` is deliberately not cached.** A server error is not a decision — the
  write may have half-happened or not happened at all — and caching it would
  pin the caller to a failure they can never retry past, which is the opposite
  of what an idempotency key is for. The claim row is released instead, so the
  next attempt is a real attempt.

  ## Concurrency

  The claim is inserted *before* the request runs, under a unique index on
  `(caller, key)`. A second request arriving while the first is in flight
  therefore loses the insert and is answered `409 idempotency_key_in_progress`
  rather than being allowed to run in parallel — which is the case the naive
  "check, then act" version gets wrong.

  ## Scoping

  Keyed by `(caller, key)`, never `key` alone. Callers generate their own keys
  and two services choosing the same UUID must not collide; it also stops one
  caller pulling back another's response by guessing.
  """

  import Ecto.Query, warn: false

  alias Scheduling.Idempotency.Key
  alias Scheduling.Repo

  @retention_hours 24

  @typedoc """
  What a caller's key means right now.

    * `{:replay, key}` — decided already; return the stored response.
    * `{:claimed, key}` — first time; run the request, then call `settle/4`.
    * `:in_progress` — another request holds the claim and has not finished.
    * `{:mismatch, key}` — same key, different request. Refuse.
  """
  @type claim ::
          {:replay, Key.t()} | {:claimed, Key.t()} | :in_progress | {:mismatch, Key.t()}

  @doc """
  Claims `key` for `caller`, or reports why it cannot be claimed.

  `fingerprint` identifies the request itself — see `fingerprint/3`.
  """
  @spec claim(String.t(), String.t(), String.t()) :: claim()
  def claim(caller, key, fingerprint) do
    case Repo.insert(
           Key.claim_changeset(%{caller: caller, key: key, request_fingerprint: fingerprint})
         ) do
      {:ok, claimed} ->
        {:claimed, claimed}

      {:error, _changeset} ->
        # Lost the race, or this key has been used before. Which one is a
        # question about the existing row, not about our insert.
        existing = Repo.get_by!(Key, caller: caller, key: key)

        cond do
          existing.request_fingerprint != fingerprint -> {:mismatch, existing}
          Key.settled?(existing) -> {:replay, existing}
          true -> :in_progress
        end
    end
  end

  @doc """
  Records the response a claimed key produced.

  A `5xx` releases the claim instead of storing it — see the moduledoc.
  """
  @spec settle(Key.t(), non_neg_integer(), binary(), String.t() | nil) :: :ok
  def settle(%Key{} = key, status, _body, _content_type) when status >= 500 do
    _ = Repo.delete(key)
    :ok
  end

  def settle(%Key{} = key, status, body, content_type) do
    key
    |> Key.response_changeset(%{
      response_status: status,
      response_body: body,
      response_content_type: content_type
    })
    |> Repo.update!()

    :ok
  end

  @doc """
  Releases a claim without recording a response.

  For the case where the request never produced one at all — the process died,
  or the connection was dropped mid-handler. Leaving the claim would lock the
  caller out of retrying under that key until the sweeper caught up.
  """
  @spec release(Key.t()) :: :ok
  def release(%Key{} = key) do
    _ = Repo.delete(key)
    :ok
  end

  @doc """
  A stable digest of the request, so a recycled key is caught.

  Map keys are sorted recursively before encoding: two JSON bodies that differ
  only in field order are the same request, and treating them as different
  would reject a legitimate retry from a client that does not preserve order.
  """
  @spec fingerprint(String.t(), String.t(), term()) :: String.t()
  def fingerprint(method, path, params) do
    canonical = Jason.encode!(canonicalise(params))

    :sha256
    |> :crypto.hash(method <> "\n" <> path <> "\n" <> canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonicalise(%{__struct__: _} = struct), do: inspect(struct)

  # Emitted as a sorted list of [key, value] pairs rather than a map: a JSON
  # object gives no ordering guarantee on the way out, so encoding a map would
  # reintroduce exactly the instability this is meant to remove.
  defp canonicalise(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> [to_string(k), canonicalise(v)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonicalise(list) when is_list(list), do: Enum.map(list, &canonicalise/1)
  defp canonicalise(other), do: other

  @doc "How long a settled key is honoured before the sweeper removes it."
  @spec retention_hours() :: pos_integer()
  def retention_hours, do: @retention_hours

  @doc """
  Deletes keys past their retention window. Returns how many went.

  Claims are swept on the same schedule. An abandoned claim — a process that
  died between claiming and settling — would otherwise block that caller from
  ever reusing the key.
  """
  @spec delete_expired() :: non_neg_integer()
  def delete_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_hours, :hour)

    {count, _} = Key |> where([k], k.inserted_at < ^cutoff) |> Repo.delete_all()
    count
  end
end
