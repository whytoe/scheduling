defmodule SchedulingWeb.Plugs.BrowserAuth do
  @moduledoc """
  Session handling and route guards for the browser UI.

  Three plugs, composed by the router:

    * `fetch_current_scope/2` — always runs; puts `conn.assigns.current_scope`
      (a `Scheduling.Auth.Scope`, or `nil` when signed out or auth is
      disabled). Never redirects, so public pages can render a "sign in"
      affordance.
    * `require_authenticated/2` — redirects anonymous users to `/auth/login`,
      remembering where they were going.
    * `require_role/2` — 403s an authenticated user whose roles don't cover
      the route.

  Every one of them is a pass-through when `Scheduling.Auth.enabled?/0` is
  false, which is what keeps an unconfigured local checkout usable.

  ## Session lifetime

  The stored identity's `exp` is *our* deadline
  (`Scheduling.Auth.session_ttl_seconds/0`, 8h by default), not the ID
  token's. Keycloak ID tokens expire in about five minutes; honouring that
  literally would bounce an operator through the IdP mid-shift, repeatedly,
  for no security gain — the thing that actually governs whether they must
  retype a password is the Keycloak SSO session, which we do not control and
  should not second-guess. What our deadline guarantees is that a stolen
  session cookie stops working, and that role changes at the IdP take effect
  within the day.
  """

  @behaviour Plug

  use SchedulingWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Scheduling.Auth
  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Scope

  @identity_key "auth_identity"
  @return_to_key :auth_return_to

  @doc "Session key holding the serialised identity. Shared with the LiveView hooks."
  @spec identity_key() :: String.t()
  def identity_key, do: @identity_key

  # Plug behaviour, so the router can name one module and pick the step:
  #
  #     plug BrowserAuth, :fetch_current_scope
  #     plug BrowserAuth, {:require_role, ["admin"]}
  @impl Plug
  def init(step), do: step

  @impl Plug
  def call(conn, :fetch_current_scope), do: fetch_current_scope(conn, [])
  def call(conn, :require_authenticated), do: require_authenticated(conn, [])
  def call(conn, {:require_role, roles}), do: require_role(conn, roles)

  @doc """
  Assigns `current_scope` from the session. Runs on every browser request.
  """
  @spec fetch_current_scope(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope(conn, _opts) do
    assign(conn, :current_scope, scope_from_session(get_session(conn, @identity_key)))
  end

  @doc """
  Builds a scope from a serialised session identity, or `nil` when there is
  none or it has expired. Shared with `SchedulingWeb.AuthHooks` so a LiveView
  reaches the same verdict as the plug pipeline.
  """
  @spec scope_from_session(term()) :: Scope.t() | nil
  def scope_from_session(data) do
    case Identity.from_session(data) do
      nil -> nil
      identity -> if expired?(identity), do: nil, else: Scope.for_identity(identity)
    end
  end

  @doc """
  Puts a freshly authenticated identity in the session.

  The session is renewed first: a fixated pre-login session id must not carry
  over into the authenticated one.
  """
  @spec log_in(Plug.Conn.t(), Identity.t()) :: Plug.Conn.t()
  def log_in(conn, %Identity{} = identity) do
    identity = %{identity | expires_at: System.system_time(:second) + Auth.session_ttl_seconds()}

    conn
    |> configure_session(renew: true)
    |> put_session(@identity_key, Identity.to_session(identity))
    |> put_session(:live_socket_id, "auth_sessions:" <> random_id())
    |> assign(:current_scope, Scope.for_identity(identity))
  end

  @doc """
  Drops the local session and disconnects any LiveViews it is driving.

  Without `disconnect_live_socket`, an already-open board would keep streaming
  on its established socket until the operator navigated.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      SchedulingWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> assign(:current_scope, nil)
  end

  @doc "Redirects anonymous users to the IdP, remembering the current path."
  @spec require_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated(conn, _opts) do
    cond do
      not Auth.enabled?() ->
        conn

      conn.assigns[:current_scope] ->
        conn

      true ->
        conn
        |> put_return_to(current_path_for(conn))
        |> redirect(to: ~p"/auth/login")
        |> halt()
    end
  end

  @doc """
  Requires one of `roles` (plus the implicit `admin`). Assumes
  `require_authenticated/2` ran first.
  """
  @spec require_role(Plug.Conn.t(), [String.t()] | String.t()) :: Plug.Conn.t()
  def require_role(conn, roles) do
    roles = List.wrap(roles)

    if not Auth.enabled?() or Scope.has_any_role?(conn.assigns[:current_scope], roles) do
      conn
    else
      # AuthHTML renders a complete document, so both layouts come off.
      conn
      |> put_status(:forbidden)
      |> put_root_layout(html: false)
      |> put_layout(false)
      |> put_view(html: SchedulingWeb.AuthHTML)
      |> render(:forbidden, roles: roles)
      |> halt()
    end
  end

  @doc """
  Remembers where to land after login. Only local paths are stored — an
  absolute URL here would turn `/auth/login?return_to=` into an open redirect.
  """
  @spec put_return_to(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  def put_return_to(conn, path) do
    if local_path?(path), do: put_session(conn, @return_to_key, path), else: conn
  end

  @doc "Reads and clears the remembered path, defaulting to the board."
  @spec take_return_to(Plug.Conn.t()) :: String.t()
  def take_return_to(conn) do
    case get_session(conn, @return_to_key) do
      path when is_binary(path) -> if local_path?(path), do: path, else: ~p"/board"
      _ -> ~p"/board"
    end
  end

  defp expired?(%Identity{expires_at: exp}) when is_integer(exp) do
    exp <= System.system_time(:second)
  end

  # No expiry recorded means the session predates this field or was hand-made.
  # Treat it as expired rather than as eternal.
  defp expired?(_identity), do: true

  # "//evil.example" and "/\evil.example" are protocol-relative URLs that
  # browsers follow off-site, so a leading "/" alone is not enough.
  defp local_path?("/" <> rest = path) when is_binary(path) do
    not String.starts_with?(rest, "/") and not String.starts_with?(rest, "\\")
  end

  defp local_path?(_), do: false

  # Per-session, not per-user: logging out on one machine should not knock the
  # same operator off the board they left running at the nurses' station.
  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp current_path_for(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end
end
