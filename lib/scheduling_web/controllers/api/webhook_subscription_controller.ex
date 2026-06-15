defmodule SchedulingWeb.Api.WebhookSubscriptionController do
  @moduledoc """
  JSON API for managing outbound webhook subscriptions. Each active
  subscription receives signed POST requests for the configured event
  types — see `Scheduling.Webhooks` for the signing scheme.

  IMPORTANT: the `secret` is returned ONLY in the response to
  `POST /webhook_subscriptions`. List and show responses omit it.
  Rotation = issue a new subscription, not mutate in place.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Webhooks
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["webhook_subscriptions"])

  operation(:index,
    summary: "List webhook subscriptions",
    responses: [ok: {"Subscriptions", "application/json", Schemas.WebhookSubscriptionList}]
  )

  def index(conn, _params) do
    json(conn, Enum.map(Webhooks.list_subscriptions(), &serialize/1))
  end

  operation(:show,
    summary: "Get one webhook subscription",
    parameters: [id: [in: :path, type: :integer]],
    responses: [
      ok: {"Subscription", "application/json", Schemas.WebhookSubscription},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, sub} <- fetch(id) do
      json(conn, serialize(sub))
    end
  end

  operation(:create,
    summary: "Create a webhook subscription",
    description:
      "On create the response includes the auto-generated `secret`. **This is the only opportunity to capture the secret.** Subsequent reads do not return it.",
    request_body: {"Subscription attrs", "application/json", Schemas.WebhookSubscriptionRequest},
    responses: [
      created: {"Created", "application/json", Schemas.WebhookSubscriptionCreated},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def create(conn, %{"webhook_subscription" => params}) do
    with {:ok, sub} <- Webhooks.create_subscription(params) do
      conn |> put_status(:created) |> json(serialize_with_secret(sub))
    end
  end

  operation(:update,
    summary: "Update a webhook subscription",
    parameters: [id: [in: :path, type: :integer]],
    request_body: {"Subscription attrs", "application/json", Schemas.WebhookSubscriptionRequest},
    responses: [
      ok: {"Updated", "application/json", Schemas.WebhookSubscription},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def update(conn, %{"id" => id, "webhook_subscription" => params}) do
    with {:ok, sub} <- fetch(id),
         {:ok, updated} <- Webhooks.update_subscription(sub, params) do
      json(conn, serialize(updated))
    end
  end

  operation(:delete,
    summary: "Delete a webhook subscription",
    parameters: [id: [in: :path, type: :integer]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, sub} <- fetch(id),
         {:ok, _} <- Webhooks.delete_subscription(sub) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Webhooks.get_subscription!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(sub) do
    %{
      id: sub.id,
      url: sub.url,
      event_types: sub.event_types || [],
      active: sub.active,
      description: sub.description,
      inserted_at: sub.inserted_at,
      updated_at: sub.updated_at
    }
  end

  defp serialize_with_secret(sub), do: Map.put(serialize(sub), :secret, sub.secret)
end
