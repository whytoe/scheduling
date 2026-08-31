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
  The ac-core location ids this scope may work in, or `nil` for unrestricted.

  `nil` is the permissive answer and is returned in three cases, all
  deliberate:

    * **No scope at all.** Auth is disabled; there is nobody to restrict.
    * **The identity carries no location claim.** Scoping is inactive for that
      person — see `Scheduling.Auth.location_claim/0` for why absent means
      unrestricted rather than the reverse.
    * **The identity is an admin.** An admin already administers offices,
      capabilities and availability across the whole deployment; granting them
      a subset of sites would half-break administration in a way that reads as
      a bug rather than a policy. `admin` already satisfies every role check
      (`Identity.has_role?/2`), so this is consistent rather than a new
      exception.

  Callers pass the result straight to `Scheduling.Offices.list_offices/1`,
  which treats `nil` as "no filter".
  """
  @spec location_ids(t() | nil) :: [String.t()] | nil
  def location_ids(%__MODULE__{identity: identity}) do
    if Identity.has_role?(identity, "admin") do
      nil
    else
      identity.location_ids
    end
  end

  def location_ids(nil), do: nil

  @doc """
  True when this scope may act on `office`.

  The office's location is the unit of access: a person is granted a site and
  reaches every room in it. An office with no location is visible to everyone,
  because an unlinked room cannot be attributed to a site and hiding it would
  make rooms disappear from the board for no reason the operator could see.
  """
  @spec may_use_office?(t() | nil, %{optional(:location) => term()}) :: boolean()
  def may_use_office?(scope, office) do
    case location_ids(scope) do
      nil -> true
      ids -> office_location_id(office) in [nil | ids]
    end
  end

  defp office_location_id(%{location: %{core_location_id: id}}), do: id
  defp office_location_id(_office), do: nil

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
