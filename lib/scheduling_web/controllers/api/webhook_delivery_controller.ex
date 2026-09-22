defmodule SchedulingWeb.Api.WebhookDeliveryController do
  @moduledoc """
  Read-only observability for outbound webhook deliveries: what was sent, what
  came back, how many attempts, and what is dead-lettered.

  Admin-only, alongside `WebhookSubscriptionController` — an operator debugging
  why a receiver is not getting events looks here. The `dead` status is the
  dead-letter queue.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Webhooks
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["webhook_deliveries"])

  operation(:index,
    summary: "List webhook deliveries",
    description:
      "Newest first. Filters:\n\n" <>
        "- `?subscription_id=<int>` — deliveries for one subscription\n" <>
        "- `?status=pending|delivered|dead` — `dead` is the dead-letter queue\n\n" <>
        "`?limit=` caps the page (default 100).",
    parameters: [
      subscription_id: [in: :query, type: :integer, required: false],
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "pending | delivered | dead"
      ],
      limit: [in: :query, type: :integer, required: false]
    ],
    responses: [ok: {"Deliveries", "application/json", Schemas.WebhookDeliveryList}]
  )

  def index(conn, params) do
    opts =
      []
      |> put_int(:subscription_id, params["subscription_id"])
      |> put_status_filter(params["status"])
      |> put_int(:limit, params["limit"])

    json(conn, Enum.map(Webhooks.list_deliveries(opts), &serialize/1))
  end

  defp put_int(opts, _key, nil), do: opts

  defp put_int(opts, key, value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> Keyword.put(opts, key, n)
      _ -> opts
    end
  end

  defp put_status_filter(opts, nil), do: opts
  defp put_status_filter(opts, status), do: Keyword.put(opts, :status, status)

  defp serialize(d) do
    %{
      id: d.id,
      subscription_id: d.subscription_id,
      event_id: d.event_id,
      event_type: d.event_type,
      status: Atom.to_string(d.status),
      attempts: d.attempts,
      last_response_status: d.last_response_status,
      last_error: d.last_error,
      next_retry_at: d.next_retry_at,
      delivered_at: d.delivered_at,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end
end
