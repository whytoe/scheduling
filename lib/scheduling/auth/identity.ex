defmodule Scheduling.Auth.Identity do
  @moduledoc """
  Who is making this request, derived from validated OIDC token claims.

  An identity is built only from claims that have already passed signature,
  issuer, audience and expiry validation (`Scheduling.Auth.Tokens` for API
  tokens, `Oidcc.Token.validate_id_token/3` for the browser flow). Nothing
  here re-checks the token; constructing an `Identity` from unvalidated
  claims would be a bug.

  ## Actor attribution

  `actor/1` returns the `{actor_type, actor_id}` pair written to
  `visit_events`. Before auth, callers passed these in the request body, so
  the audit log recorded whatever the client asserted. Now they come from the
  token:

    * **user** — `actor_id` is the `sub` claim, the IdP's stable user id.
    * **service** — `actor_id` is the `azp` claim (the OAuth client id, e.g.
      `intake-bridge`), falling back to `sub`. A service account's `sub` is an
      opaque per-realm uuid that names nothing a human recognises; the client
      id is the service's actual identity and is what an operator reading the
      timeline needs to see.

  Keycloak marks client-credentials tokens by setting `preferred_username` to
  `service-account-<client-id>`, which is how `type/1` tells the two apart.
  """

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
          expires_at: integer() | nil
        }

  defstruct [:subject, :type, :username, :email, :name, :client_id, :roles, :expires_at]

  @doc """
  Builds an identity from validated token claims.

  `client_id` is this application's OAuth client id, used to find client roles
  under `resource_access`.
  """
  @spec from_claims(map(), String.t() | nil) :: t()
  def from_claims(claims, client_id \\ nil) when is_map(claims) do
    username = claims["preferred_username"]

    %__MODULE__{
      subject: claims["sub"],
      type: type(username),
      username: username,
      email: claims["email"],
      name: claims["name"] || claims["given_name"] || username,
      client_id: claims["azp"],
      roles: roles(claims, client_id),
      expires_at: claims["exp"]
    }
  end

  @doc """
  Serialises an identity into the plug session.

  Only these fields are stored — never the raw tokens. The session cookie is
  signed but readable by the client and capped at 4KB, and a Keycloak
  access + refresh + ID token triple can exceed that on its own. Keeping
  tokens out means there is also nothing to exfiltrate from a stolen cookie
  beyond what the identity already says.
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

  defp type(username) when is_binary(username) do
    if String.starts_with?(username, @service_account_prefix), do: :service, else: :user
  end

  defp type(_), do: :user

  # Realm roles and this client's roles are both meaningful; take the union so
  # a deployment can grant either way without the app caring which.
  defp roles(claims, client_id) do
    realm = get_in(claims, ["realm_access", "roles"]) || []

    client =
      case client_id do
        nil -> []
        id -> get_in(claims, ["resource_access", id, "roles"]) || []
      end

    (realm ++ client)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
