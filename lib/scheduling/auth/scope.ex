defmodule Scheduling.Auth.Scope do
  @moduledoc """
  The [scope](https://hexdocs.pm/phoenix/scopes.html) assigned to every
  browser request and LiveView as `current_scope`.

  Today it carries exactly one thing — the signed-in
  `Scheduling.Auth.Identity`. It exists as a struct rather than assigning the
  identity directly because `current_scope` is the Phoenix 1.8 convention that
  `SchedulingWeb.Layouts.app/1` already accepts, and because the natural next
  additions (selected office, tenant) belong beside the identity rather than
  as more top-level assigns.

  `current_scope` is `nil` only when auth is disabled — see `Scheduling.Auth`.
  """

  alias Scheduling.Auth.Identity

  @type t :: %__MODULE__{identity: Identity.t()}

  defstruct [:identity]

  @doc "Wraps an identity in a scope."
  @spec for_identity(Identity.t()) :: t()
  def for_identity(%Identity{} = identity), do: %__MODULE__{identity: identity}

  @doc "True when the scope's identity carries `role` (or is an admin)."
  @spec has_role?(t() | nil, String.t()) :: boolean()
  def has_role?(%__MODULE__{identity: identity}, role), do: Identity.has_role?(identity, role)
  def has_role?(nil, _role), do: false

  @doc "True when the scope's identity carries at least one of `roles`."
  @spec has_any_role?(t() | nil, [String.t()]) :: boolean()
  def has_any_role?(%__MODULE__{identity: identity}, roles),
    do: Identity.has_any_role?(identity, roles)

  def has_any_role?(nil, _roles), do: false

  @doc """
  The `[actor_type: ..., actor_id: ...]` options passed into the context
  functions that write `visit_events`.

  Returns `[]` for a nil scope, which is what auth-disabled deployments and
  the existing tests get — the context functions already treat missing actor
  fields as `nil`.
  """
  @spec actor_opts(t() | nil) :: keyword()
  def actor_opts(%__MODULE__{identity: identity}) do
    {type, id} = Identity.actor(identity)
    [actor_type: type, actor_id: id]
  end

  def actor_opts(nil), do: []
end
