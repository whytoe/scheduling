defmodule Scheduling.Webhooks.Subscription do
  @moduledoc """
  A webhook subscription: a URL that receives signed POST requests for one
  or more event types. `secret` is the HMAC key used to sign delivery
  bodies; rotate by issuing a new subscription rather than mutating in
  place once a subscription is in use.

  `event_types` is a list of exact event type strings (e.g.
  `"visit.created"`, `"queue_entry.completed"`). The empty list means
  "all events" — useful for monitoring sinks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "webhook_subscriptions" do
    field :url, :string
    field :secret, :string
    field :event_types, {:array, :string}, default: []
    field :active, :boolean, default: true
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @castable [:url, :secret, :event_types, :active, :description]

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @castable)
    |> maybe_generate_secret()
    |> validate_required([:url, :secret, :active])
    |> validate_length(:url, min: 1, max: 2048)
    |> validate_url(:url)
    |> validate_length(:secret, min: 16, max: 256)
  end

  defp maybe_generate_secret(changeset) do
    case get_field(changeset, :secret) do
      nil -> put_change(changeset, :secret, generate_secret())
      _ -> changeset
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp validate_url(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value ->
        case URI.new(value) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) ->
            changeset

          _ ->
            add_error(changeset, field, "must be a valid http(s) URL")
        end
    end
  end
end
