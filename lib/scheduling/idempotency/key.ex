defmodule Scheduling.Idempotency.Key do
  @moduledoc """
  One caller's use of one `Idempotency-Key`, and the response it earned.

  A row with `response_status` still null is a **claim**: some request is
  in flight under this key and has not finished. That distinction is the whole
  mechanism — it is how a concurrent duplicate is told apart from a retry of
  something already decided.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "idempotency_keys" do
    field :caller, :string
    field :key, :string
    field :request_fingerprint, :string
    field :response_status, :integer
    field :response_body, :string
    field :response_content_type, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for claiming a key, before the request has been handled."
  def claim_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:caller, :key, :request_fingerprint])
    |> validate_required([:caller, :key, :request_fingerprint])
    |> unique_constraint([:caller, :key])
  end

  @doc "Changeset recording the response a claimed key produced."
  def response_changeset(%__MODULE__{} = key, attrs) do
    cast(key, attrs, [:response_status, :response_body, :response_content_type])
  end

  @doc "True when this row holds a decided outcome rather than an open claim."
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{response_status: nil}), do: false
  def settled?(%__MODULE__{}), do: true
end
