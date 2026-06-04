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

  alias Scheduling.Repo
  alias Scheduling.Webhooks.Subscription

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
  Dispatches `event` (a `Scheduling.Audit.VisitEvent`) to every active
  subscription whose `event_types` contains `event.type` or is empty.
  Fire-and-forget: each delivery is a supervised Task.start, so a slow
  receiver doesn't slow scheduling. No retry / delivery log in this
  pass.
  """
  @spec dispatch(map()) :: :ok
  def dispatch(%{type: type} = event) when is_binary(type) do
    for sub <- list_matching(type) do
      Task.start(fn -> deliver(sub, event) end)
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

  @doc """
  Performs one delivery synchronously. Returns
  `{:ok, status}` or `{:error, reason}`. Called by `dispatch/1`'s Task
  and reusable from tests.
  """
  @spec deliver(Subscription.t(), map()) :: {:ok, integer()} | {:error, term()}
  def deliver(%Subscription{} = sub, event) do
    body =
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

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    signature = sign(sub.secret, timestamp, body)

    headers = [
      {"content-type", "application/json"},
      {"x-scheduling-event-type", Map.get(event, :type, "")},
      {"x-scheduling-timestamp", Integer.to_string(timestamp)},
      {"x-scheduling-signature", "t=#{timestamp},v1=#{signature}"}
    ]

    Req.new(
      url: sub.url,
      headers: headers,
      body: body,
      receive_timeout: 10_000,
      retry: false
    )
    |> Req.post()
    |> case do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
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
