defmodule Scheduling.Auth.Identity do
  @moduledoc """
  Who is making this request, derived from validated OIDC token claims.

  An identity is built only from claims that have already passed signature,
  issuer, audience and expiry validation (`Scheduling.Auth.Tokens` for API
  tokens, `Oidcc.Token.validate_id_token/3` for the browser flow). Nothing
  here re-checks the token; constructing an `Identity` from unvalidated
  claims would be a bug.

  ## Where roles live

  OIDC standardises `sub`, `email`, `exp` — it says nothing about roles, so
  every provider invents its own placement:

      astrum_roles                              # Astrum core-api
      realm_access.roles                        # Keycloak realm roles
      resource_access.<client_id>.roles         # Keycloak client roles
      roles                                     # the plain case

  Rather than hardcode one vendor's shape, `Scheduling.Auth.role_claims/0`
  holds a list of dotted claim paths and every one that is present is unioned.
  The default covers all four above, so both Astrum and Keycloak work without
  configuration; `OIDC_ROLE_CLAIMS` overrides it for anything else. The
  literal `<client_id>` in a path is substituted with this app's client id.

  ## Telling a user from a service

  Keycloak marks client-credentials tokens with
  `preferred_username: "service-account-<client-id>"`. Astrum sends no
  `preferred_username` at all, so that check alone would classify every
  service token as a user and file its actions in the audit log under an
  opaque uuid.

  The provider-neutral rule is the one OIDC actually implies: **a token with
  no end-user identity on it is a service token.** `email`, `sid` and
  `preferred_username` all describe a human who authenticated; a
  client-credentials grant has no human, so it carries none of them. Keycloak's
  convention is honoured too, since Keycloak *does* send `preferred_username`
  on service tokens.

  ## Actor attribution

  `actor/1` returns the `{actor_type, actor_id}` pair written to
  `visit_events`. Before auth, callers passed these in the request body, so
  the audit log recorded whatever the client asserted. Now they come from the
  token:

    * **user** — `actor_id` is the `sub` claim, the IdP's stable user id.
    * **service** — `actor_id` is the `azp` claim (the OAuth client id, e.g.
      `intake-bridge`), falling back to `sub`. A service account's `sub` is an
      opaque uuid that names nothing a human recognises; the client id is the
      service's actual identity and is what an operator reading the timeline
      needs to see.
  """

  alias Scheduling.Auth

  @service_account_prefix "service-account-"

  @known_roles ~w(admin operator viewer service)

  @type t :: %__MODULE__{
          subject: String.t(),
          type: :user | :service,
          username: String.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          client_id: String.t() | nil,
          roles: [String.t()],
          tenancy_id: String.t() | nil,
          org: String.t() | nil,
          org_id: String.t() | nil,
          tenant: String.t() | nil,
          sid: String.t() | nil,
          expires_at: integer() | nil
        }

  defstruct [
    :subject,
    :type,
    :username,
    :email,
    :name,
    :client_id,
    :roles,
    :tenancy_id,
    :org,
    :org_id,
    :tenant,
    :sid,
    :expires_at
  ]

  @doc """
  Builds an identity from validated token claims.

  `client_id` is this application's OAuth client id, used to substitute
  `<client_id>` in the configured role-claim paths.
  """
  @spec from_claims(map(), String.t() | nil) :: t()
  def from_claims(claims, client_id \\ nil) when is_map(claims) do
    %__MODULE__{
      subject: claim(claims, "sub"),
      type: type(claims),
      username: claim(claims, "preferred_username"),
      email: claim(claims, "email"),
      name:
        claim(claims, "name") || claim(claims, "given_name") ||
          claim(claims, "preferred_username"),
      client_id: claim(claims, "azp") || claim(claims, "client_id"),
      roles: roles(claims, client_id),
      tenancy_id: claim(claims, Auth.tenancy_claim()),
      org: claim(claims, Auth.org_claim()),
      org_id: claim(claims, Auth.org_id_claim()),
      tenant: claim(claims, Auth.tenant_claim()),
      # Kept so back-channel logout can name this exact session later; see
      # `Scheduling.Auth.SessionRevocation`.
      sid: claim(claims, "sid"),
      expires_at: claim(claims, "exp")
    }
  end

  @doc """
  Serialises an identity into the plug session.

  Only these fields are stored — never the raw tokens. The session cookie is
  signed but readable by the client and capped at 4KB, and an access + refresh
  + ID token triple can exceed that on its own. Keeping tokens out means there
  is also nothing to exfiltrate from a stolen cookie beyond what the identity
  already says.
  """
  @spec to_session(t()) :: map()
  def to_session(%__MODULE__{} = identity) do
    %{
      "sub" => identity.subject,
      "typ" => Atom.to_string(identity.type),
      "username" => identity.username,
      "email" => identity.email,
      "name" => identity.name,
      "azp" => identity.client_id,
      "roles" => identity.roles,
      "tenancy_id" => identity.tenancy_id,
      "org" => identity.org,
      "org_id" => identity.org_id,
      "tenant" => identity.tenant,
      "sid" => identity.sid,
      "exp" => identity.expires_at
    }
  end

  @doc "Rebuilds an identity from `to_session/1`. Returns nil on anything unexpected."
  @spec from_session(term()) :: t() | nil
  def from_session(%{"sub" => sub} = data) when is_binary(sub) do
    %__MODULE__{
      subject: sub,
      type: if(data["typ"] == "service", do: :service, else: :user),
      username: data["username"],
      email: data["email"],
      name: data["name"],
      client_id: data["azp"],
      roles: List.wrap(data["roles"]),
      tenancy_id: data["tenancy_id"],
      org: data["org"],
      org_id: data["org_id"],
      tenant: data["tenant"],
      sid: data["sid"],
      expires_at: data["exp"]
    }
  end

  def from_session(_), do: nil

  @doc """
  The `{actor_type, actor_id}` pair recorded on `visit_events` for actions
  taken by this identity. See the module doc for why services report `azp`.
  """
  @spec actor(t()) :: {String.t(), String.t()}
  def actor(%__MODULE__{type: :service} = identity) do
    {"service", identity.client_id || identity.subject}
  end

  def actor(%__MODULE__{} = identity), do: {"user", identity.subject}

  @doc "True when the identity carries `role`. `admin` satisfies every role."
  @spec has_role?(t(), String.t()) :: boolean()
  def has_role?(%__MODULE__{roles: roles}, role) do
    "admin" in roles or role in roles
  end

  @doc "True when the identity carries at least one of `roles`."
  @spec has_any_role?(t(), [String.t()]) :: boolean()
  def has_any_role?(%__MODULE__{} = identity, roles) do
    Enum.any?(roles, &has_role?(identity, &1))
  end

  @doc """
  True when the identity may read. Any recognised role grants read; an
  authenticated token with no recognised role at all does not.
  """
  @spec can_read?(t()) :: boolean()
  def can_read?(%__MODULE__{} = identity), do: has_any_role?(identity, @known_roles)

  @doc "Roles this app recognises. Everything else on the token grants nothing."
  @spec known_roles() :: [String.t()]
  def known_roles, do: @known_roles

  @doc "Display label for the identity — what the navbar shows."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{} = identity) do
    identity.name || identity.username || identity.email || identity.subject
  end

  # See "Telling a user from a service" above.
  defp type(claims) do
    username = claim(claims, "preferred_username")

    cond do
      is_binary(username) and String.starts_with?(username, @service_account_prefix) ->
        :service

      is_nil(claim(claims, "email")) and is_nil(claim(claims, "sid")) and is_nil(username) ->
        :service

      true ->
        :user
    end
  end

  # Reads a claim, normalising "absent" to nil.
  #
  # `oidcc` decodes a JSON `null` to the atom `:null`, not to `nil`, so a
  # provider that sends `"email": null` rather than omitting the key produces a
  # value that `is_nil/1` does not catch — which would have classified every
  # such service token as a user and stored `:null` as somebody's email.
  # Empty strings get the same treatment for the same reason.
  defp claim(claims, key) do
    case Map.get(claims, key) do
      nil -> nil
      :null -> nil
      "" -> nil
      value -> value
    end
  end

  # Union of every configured role-claim path that is present, so a deployment
  # can grant roles whichever way its provider models them.
  defp roles(claims, client_id) do
    Auth.role_claims()
    |> Enum.flat_map(&read_claim_path(claims, &1, client_id))
    # is_binary/1 also drops any `:null` the provider put in the list.
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp read_claim_path(claims, path, client_id) do
    path
    |> String.split(".")
    |> Enum.map(&substitute_client_id(&1, client_id))
    |> case do
      # A path naming <client_id> when no client id is configured cannot match.
      segments -> if Enum.any?(segments, &is_nil/1), do: [], else: get_in_claims(claims, segments)
    end
  end

  defp substitute_client_id("<client_id>", client_id), do: client_id
  defp substitute_client_id(segment, _client_id), do: segment

  defp get_in_claims(:null, []), do: []
  defp get_in_claims(value, []), do: List.wrap(value)

  defp get_in_claims(claims, [segment | rest]) when is_map(claims) do
    get_in_claims(Map.get(claims, segment), rest)
  end

  defp get_in_claims(_value, _segments), do: []
end
