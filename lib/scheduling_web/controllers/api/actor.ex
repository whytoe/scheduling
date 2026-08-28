defmodule SchedulingWeb.Api.Actor do
  @moduledoc """
  Resolves the `{actor_type, actor_id}` pair recorded on `visit_events` for a
  mutating API call.

  Before authentication, callers asserted their own identity in the request
  body — so the audit log recorded whatever the client claimed, and any client
  could attribute an action to anyone. `docs/integrations.md` flagged this as
  provisional: "Once `sc-6ea` (OAuth) lands, these come from the bearer
  token's subject claim."

  That is now the behaviour. When a validated token is present its subject
  wins, and `actor_type` / `actor_id` in the body are **ignored** rather than
  merged — a token that says `service:intake-bridge` must not be able to write
  an audit row blaming a named clinician.

  The body is still read when auth is disabled, which is what keeps the
  unconfigured local-dev quickstart and the existing API tests meaningful.
  """

  alias Scheduling.Auth.Identity

  @doc """
  Actor options for the context functions, given the conn and the request body.

  Returns `[]` when there is neither a token nor body attribution — the
  context functions already treat missing actor fields as `nil`.
  """
  @spec opts(Plug.Conn.t(), map()) :: keyword()
  def opts(conn, body \\ %{}) do
    case conn.assigns[:current_identity] do
      %Identity{} = identity ->
        {type, id} = Identity.actor(identity)
        [actor_type: type, actor_id: id]

      nil ->
        from_body(body)
    end
  end

  defp from_body(body) do
    [actor_type: Map.get(body, "actor_type"), actor_id: Map.get(body, "actor_id")]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
