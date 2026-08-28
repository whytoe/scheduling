defmodule SchedulingWeb.AuthHooks do
  @moduledoc """
  `on_mount` hooks that give LiveViews the same `current_scope` the plug
  pipeline builds for controllers.

  A LiveView mounts twice — once over HTTP (where the plug pipeline has
  already run) and again over the websocket (where it has not). Only the
  session map crosses to the websocket, so these hooks re-derive the scope
  from it via `SchedulingWeb.Plugs.BrowserAuth.scope_from_session/1`. That
  shared function is the point: the socket must not be able to reach a more
  permissive verdict than the pipeline did.

      live_session :authenticated,
        on_mount: [{SchedulingWeb.AuthHooks, :require_authenticated}] do
        live "/board", BoardLive.Index, :index
      end

  Note that `live_session` is what makes this a real boundary. LiveView only
  skips re-running hooks when navigating *within* one session, so a
  `live_patch` cannot carry a mounted socket into a route that requires more
  than the one it mounted under.
  """

  use SchedulingWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Scheduling.Auth
  alias Scheduling.Auth.Scope
  alias SchedulingWeb.Plugs.BrowserAuth

  @doc false
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, assign_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_scope(socket, session)

    cond do
      not Auth.enabled?() -> {:cont, socket}
      socket.assigns.current_scope -> {:cont, socket}
      true -> {:halt, redirect(socket, to: ~p"/auth/login")}
    end
  end

  def on_mount({:require_role, roles}, _params, session, socket) do
    socket = assign_scope(socket, session)
    roles = List.wrap(roles)

    cond do
      not Auth.enabled?() ->
        {:cont, socket}

      is_nil(socket.assigns.current_scope) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      Scope.has_any_role?(socket.assigns.current_scope, roles) ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> put_flash(:error, forbidden_message(roles))
         |> redirect(to: ~p"/board")}
    end
  end

  defp assign_scope(socket, session) do
    assign(
      socket,
      :current_scope,
      BrowserAuth.scope_from_session(session[BrowserAuth.identity_key()])
    )
  end

  defp forbidden_message(roles) do
    Gettext.dgettext(
      SchedulingWeb.Gettext,
      "default",
      "That screen requires the %{roles} role.",
      roles: Enum.join(roles, " or ")
    )
  end
end
