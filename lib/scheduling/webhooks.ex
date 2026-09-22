defmodule Scheduling.Webhooks do
  @moduledoc """
  Outbound webhooks: subscriptions CRUD + fan-out + HMAC signing.

  When a `VisitEvent` is recorded, every active subscription whose
  `event_types` includes that type (or is empty == "all") receives an
  HTTP POST containing the serialized event. Delivery is fire-and-forget
  via `Task.start`: the producer is not blocked by slow consumers, but
  there is no retry / delivery log yet (sc-4ey-equivalent follow-up
  beads sc-* track that).

  Each delivery carries:
    * `Content-Type: application/json`
    * `X-Scheduling-Event-Type: <type>` (e.g. visit.created)
    * `X-Scheduling-Timestamp: <unix-seconds>` — when we signed
    * `X-Scheduling-Signature: t=<ts>,v1=<hex>`
       where `hex = HMAC-SHA256(secret, "<ts>.<raw_body>")`.

  Receivers verify by recomputing the signature with their stored
  secret. The timestamp prevents replay.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Scheduling.Repo
  alias Scheduling.Webhooks.Delivery
  alias Scheduling.Webhooks.Subscription

  # Waits between attempts: 5s, 30s, 5m, 30m, 2h. Overridable via config.
  @backoff_seconds [5, 30, 300, 1800, 7200]
  # Give up (dead-letter) after this many failed attempts.
  @max_attempts 5
  # Disable a subscription after this many consecutive failed attempts.
  @auto_disable_after 50

  # --- CRUD ---

  @doc "Lists every subscription, newest first."
  def list_subscriptions do
    Subscription
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> Repo.all()
  end

  @doc "Fetches a subscription by id. Raises if missing."
  def get_subscription!(id), do: Repo.get!(Subscription, id)

  @doc "Creates a subscription. Auto-generates a secret if not supplied."
  def create_subscription(attrs \\ %{}) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a subscription."
  def update_subscription(%Subscription{} = sub, attrs) do
    sub
    |> Subscription.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a subscription."
  def delete_subscription(%Subscription{} = sub), do: Repo.delete(sub)

  @doc "Returns a changeset (for forms / validation previews)."
  def change_subscription(%Subscription{} = sub, attrs \\ %{}) do
    Subscription.changeset(sub, attrs)
  end

  # --- Fan-out ---

  @doc """
  Enqueues `event` (a `Scheduling.Audit.VisitEvent`) for every active
  subscription whose `event_types` contains `event.type` or is empty.

  One `Delivery` row is written per matching subscription, `:pending` and due
  now. Because this is called from `Scheduling.Audit.record_event/1` — inside
  the same transaction as the event insert — the event and its deliveries
  commit together: no event is ever recorded without its fan-out enqueued, and
  none is enqueued for an event that rolled back. `Scheduling.Webhooks.Sweeper`
  then drains them, so a slow or down receiver no longer drops the event.
  """
  @spec dispatch(map()) :: :ok
  def dispatch(%{type: type} = event) when is_binary(type) do
    now = now()
    body = build_body(event)

    for sub <- list_matching(type) do
      %Delivery{}
      |> Delivery.changeset(%{
        subscription_id: sub.id,
        event_id: Map.get(event, :id),
        event_type: type,
        body: body,
        status: :pending,
        attempts: 0,
        next_retry_at: now
      })
      |> Repo.insert()
    end

    :ok
  end

  def dispatch(_), do: :ok

  @doc false
  def list_matching(type) when is_binary(type) do
    Subscription
    |> where([s], s.active == true)
    |> where([s], fragment("? = '{}'", s.event_types) or ^type in s.event_types)
    |> Repo.all()
  end

  # --- Delivery queue: drain, retry, dead-letter ---

  @doc """
  Attempts every delivery that is due — `:pending` with `next_retry_at <= now`
  — oldest first. Returns the number attempted. Driven on an interval by
  `Scheduling.Webhooks.Sweeper`; called directly by tests.

  `:limit` caps one drain (default 100), so a large backlog is worked in
  batches rather than one unbounded pass.
  """
  @spec deliver_due(keyword()) :: non_neg_integer()
  def deliver_due(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    now = now()

    Delivery
    |> where([d], d.status == :pending and d.next_retry_at <= ^now)
    |> order_by([d], asc: d.next_retry_at, asc: d.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&attempt_delivery/1)
    |> length()
  end

  @doc """
  Runs one delivery attempt and records the outcome.

  On a `2xx` the delivery is `:delivered` and the subscription's
  consecutive-failure count resets. On anything else — a non-2xx status or a
  transport error — it schedules the next retry on the configured backoff, or
  moves the delivery to `:dead` once `max_attempts` is reached, and bumps the
  subscription's consecutive-failure count. Crossing the auto-disable threshold
  deactivates the subscription so a permanently-dead endpoint is not retried
  against forever.
  """
  @spec attempt_delivery(Delivery.t()) :: Delivery.t()
  def attempt_delivery(%Delivery{} = delivery) do
    sub = Repo.get(Subscription, delivery.subscription_id)
    attempts = delivery.attempts + 1

    case post(sub, delivery.event_type, delivery.body) do
      {:ok, status} when status in 200..299 ->
        on_success(delivery, sub, attempts, status)

      {:ok, status} ->
        on_failure(delivery, sub, attempts, response_status: status)

      {:error, reason} ->
        on_failure(delivery, sub, attempts, error: inspect(reason))
    end
  end

  defp on_success(delivery, sub, attempts, status) do
    reset_subscription_failures(sub)

    update_delivery(delivery, %{
      status: :delivered,
      attempts: attempts,
      last_response_status: status,
      last_error: nil,
      next_retry_at: nil,
      delivered_at: now()
    })
  end

  defp on_failure(delivery, sub, attempts, outcome) do
    bump_subscription_failures(sub)

    base = %{
      attempts: attempts,
      last_response_status: Keyword.get(outcome, :response_status),
      last_response_body: nil,
      last_error: Keyword.get(outcome, :error)
    }

    if attempts >= max_attempts() do
      Logger.warning(
        "Webhook delivery #{delivery.id} to subscription #{delivery.subscription_id} " <>
          "dead-lettered after #{attempts} attempts"
      )

      update_delivery(delivery, Map.merge(base, %{status: :dead, next_retry_at: nil}))
    else
      next = DateTime.add(now(), backoff_for(attempts), :second)
      update_delivery(delivery, Map.merge(base, %{status: :pending, next_retry_at: next}))
    end
  end

  # The wait before the (attempts+1)-th try, clamped to the last configured
  # step so an over-large max_attempts still has a delay to use.
  defp backoff_for(attempts) do
    steps = backoff_seconds()
    Enum.at(steps, attempts - 1, List.last(steps))
  end

  defp update_delivery(delivery, attrs) do
    delivery
    |> Delivery.changeset(attrs)
    |> Repo.update!()
  end

  defp reset_subscription_failures(nil), do: :ok

  defp reset_subscription_failures(%Subscription{consecutive_failures: 0}), do: :ok

  defp reset_subscription_failures(%Subscription{} = sub) do
    sub |> Ecto.Changeset.change(consecutive_failures: 0) |> Repo.update!()
  end

  defp bump_subscription_failures(nil), do: :ok

  defp bump_subscription_failures(%Subscription{} = sub) do
    failures = sub.consecutive_failures + 1
    changes = %{consecutive_failures: failures}

    changes =
      if sub.active and failures >= auto_disable_after() do
        Logger.warning(
          "Disabling webhook subscription #{sub.id} after #{failures} consecutive failures"
        )

        Map.put(changes, :active, false)
      else
        changes
      end

    sub |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  @doc """
  Lists delivery rows, newest first. Filters: `:subscription_id`, `:status`
  (atom or string), `:limit` (default 100). For the operator observability API.
  """
  @spec list_deliveries(keyword()) :: [Delivery.t()]
  def list_deliveries(opts \\ []) do
    Delivery
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> filter_deliveries(opts)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp filter_deliveries(query, opts) do
    query
    |> maybe_where(:subscription_id, Keyword.get(opts, :subscription_id))
    |> maybe_where(:status, normalize_status(Keyword.get(opts, :status)))
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [d], field(d, ^field) == ^value)

  defp normalize_status(nil), do: nil
  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    if status in Enum.map(Delivery.statuses(), &Atom.to_string/1),
      do: String.to_existing_atom(status),
      else: :__none__
  end

  # --- Delivery mechanics ---

  @doc """
  Performs one delivery synchronously. Returns `{:ok, status}` or
  `{:error, reason}`. Reusable from tests and the raw path.
  """
  @spec deliver(Subscription.t(), map()) :: {:ok, integer()} | {:error, term()}
  def deliver(%Subscription{} = sub, event) do
    post(sub, Map.get(event, :type, ""), build_body(event))
  end

  # The exact JSON we POST for an event. Snapshotted into the delivery row at
  # enqueue, so a retry re-sends byte-for-byte what the first attempt did.
  defp build_body(event) do
    Jason.encode!(%{
      type: Map.get(event, :type),
      id: Map.get(event, :id),
      visit_id: Map.get(event, :visit_id),
      queue_entry_id: Map.get(event, :queue_entry_id),
      patient_id: Map.get(event, :patient_id),
      handoff_id: Map.get(event, :handoff_id),
      actor_type: Map.get(event, :actor_type),
      actor_id: Map.get(event, :actor_id),
      payload: Map.get(event, :payload, %{}),
      occurred_at: Map.get(event, :occurred_at)
    })
  end

  # Signs `body` with a fresh timestamp and POSTs it. `nil` subscription (a
  # deleted one, cascade-safe) reports an error rather than raising.
  defp post(nil, _event_type, _body), do: {:error, :subscription_missing}

  defp post(%Subscription{} = sub, event_type, body) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    signature = sign(sub.secret, timestamp, body)

    headers = [
      {"content-type", "application/json"},
      {"x-scheduling-event-type", event_type},
      {"x-scheduling-timestamp", Integer.to_string(timestamp)},
      {"x-scheduling-signature", "t=#{timestamp},v1=#{signature}"}
    ]

    Req.new(url: sub.url, headers: headers, body: body, receive_timeout: 10_000, retry: false)
    |> Req.post()
    |> case do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Config ---

  @doc "Seconds to wait between attempts. Overridable via config."
  @spec backoff_seconds() :: [pos_integer()]
  def backoff_seconds, do: config(:backoff_seconds, @backoff_seconds)

  @doc "How many attempts before a delivery is dead-lettered."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: config(:max_attempts, @max_attempts)

  @doc "Consecutive failures before a subscription is auto-disabled."
  @spec auto_disable_after() :: pos_integer()
  def auto_disable_after, do: config(:auto_disable_after, @auto_disable_after)

  defp config(key, default) do
    Application.get_env(:scheduling, __MODULE__, []) |> Keyword.get(key, default)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Fires a synthetic `webhook.test` event at a subscription so an integrator can
  verify their endpoint and signature handling without waiting for a real event.

  Synchronous and one-off: it POSTs down the same `deliver/2` path a real event
  takes — same headers, same signature scheme — and returns the receiver's HTTP
  status (or a transport error) so the result is visible inline. It does not
  record a delivery or enqueue anything.
  """
  @spec send_test(Subscription.t()) :: {:ok, integer()} | {:error, term()}
  def send_test(%Subscription{} = sub) do
    deliver(sub, %{
      type: "webhook.test",
      payload: %{
        message:
          "Test delivery from Scheduling. If your receiver verified this " <>
            "signature, it is set up correctly."
      },
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  # --- Signing ---

  @doc """
  Returns the lowercase-hex HMAC-SHA256 of `"<unix_ts>.<body>"` using
  `secret` as the key. Receivers recompute this and constant-time-
  compare to the `v1=` part of the `X-Scheduling-Signature` header.
  """
  @spec sign(String.t(), integer(), iodata()) :: String.t()
  def sign(secret, timestamp, body)
      when is_binary(secret) and is_integer(timestamp) do
    payload = [Integer.to_string(timestamp), ".", body]
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies a signature given a `X-Scheduling-Signature` header value, the
  `X-Scheduling-Timestamp` header value, the raw request body, the
  secret, and a max-age in seconds. Returns `:ok` or `{:error, reason}`.

  This is a convenience for consumers writing receivers in Elixir; the
  scheduling app itself only signs.
  """
  @spec verify_signature(String.t(), String.t() | integer(), iodata(), String.t(), integer()) ::
          :ok | {:error, atom()}
  def verify_signature(signature_header, timestamp, body, secret, max_age_seconds \\ 300) do
    with {:ok, ts} <- parse_timestamp(timestamp),
         :ok <- check_age(ts, max_age_seconds),
         {:ok, sig_hex} <- parse_signature_v1(signature_header) do
      expected = sign(secret, ts, body)

      if Plug.Crypto.secure_compare(sig_hex, expected) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp parse_timestamp(ts) when is_integer(ts), do: {:ok, ts}

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_timestamp}
    end
  end

  defp parse_timestamp(_), do: {:error, :bad_timestamp}

  defp check_age(ts, max_age) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    if now - ts <= max_age, do: :ok, else: {:error, :stale_timestamp}
  end

  defp parse_signature_v1(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      case String.trim(part) |> String.split("=", parts: 2) do
        ["v1", hex] -> {:ok, hex}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      _ -> {:error, :no_signature}
    end
  end
end
