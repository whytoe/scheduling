defmodule SchedulingWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SchedulingWeb, :html

  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Scope

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :active, :atom,
    default: nil,
    doc:
      "the active nav tab — one of :board, :queue, :decisions, :visit_events, :visits, :offices, :capabilities, :diagnoses, :availability"

  attr :wide, :boolean, default: false, doc: "use the wider page container"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  # The last three are the catalog screens, which the router puts behind the
  # admin `live_session`. They are dropped from the nav for everyone else —
  # a tab that always 403s is worse than no tab.
  @nav [
    {:board, "Board", "hero-squares-2x2", "/board", nil},
    {:queue, "Queue", "hero-queue-list", "/queue", nil},
    {:appointments, "Appointments", "hero-calendar-days", "/appointments", nil},
    {:decisions, "Decisions", "hero-document-magnifying-glass", "/decisions", nil},
    {:visit_events, "Visit events", "hero-clock", "/visit_events", nil},
    {:visits, "Visits", "hero-rectangle-stack", "/visits", nil},
    {:offices, "Offices", "hero-building-office", "/offices", "admin"},
    {:capabilities, "Capabilities", "hero-beaker", "/capabilities", "admin"},
    {:diagnoses, "Diagnoses", "hero-clipboard-document-list", "/diagnoses", "admin"},
    {:availability, "Availability", "hero-calendar-days", "/availability", "admin"}
  ]

  def app(assigns) do
    assigns = assign(assigns, :nav, visible_nav(assigns[:current_scope]))

    ~H"""
    <div class="app">
      <header class="appnav">
        <.link navigate={~p"/board"} class="navbar__brand">
          <span class="navbar__logo"><.icon name="hero-squares-2x2" class="size-[17px]" /></span>
          <span class="navbar__title">Scheduling</span>
        </.link>
        <nav class="navbar__nav" aria-label={gettext("Primary")}>
          <.link
            :for={{id, label, icon, path, _role} <- @nav}
            navigate={path}
            class={["navlink", @active == id && "navlink--active"]}
            aria-current={@active == id && "page"}
          >
            <.icon name={icon} class="size-4" />{label}
          </.link>
          <a href="/api/swagger" class="navlink" title={gettext("Opens Swagger UI at /api/swagger")}>
            <.icon name="hero-code-bracket" class="size-4" />API
            <.icon name="hero-arrow-top-right-on-square" class="navlink__ext size-3" />
          </a>
        </nav>
        <.user_menu scope={@current_scope} />
        <.theme_toggle />
      </header>

      <main class={["page", @wide && "page--wide"]}>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # With auth off there is no scope to check, so everything shows — same
  # principle as the plugs, which pass everything through in that mode.
  defp visible_nav(nil) do
    if Scheduling.Auth.enabled?(), do: Enum.filter(@nav, &is_nil(elem(&1, 4))), else: @nav
  end

  defp visible_nav(scope) do
    Enum.filter(@nav, fn {_id, _label, _icon, _path, role} ->
      is_nil(role) or Scope.has_role?(scope, role)
    end)
  end

  @doc """
  Who is signed in, and the way out.

  Renders nothing when `scope` is nil — that is the auth-disabled case, where
  a "sign out" control would lead somewhere that immediately bounces back.

  The role is shown next to the name because this app's screens differ by
  role: an operator who cannot see the Offices tab should be able to tell at a
  glance that this is their account, not a broken page.
  """
  attr :scope, :map, default: nil

  def user_menu(assigns) do
    ~H"""
    <div :if={@scope} class="navbar__user">
      <span class="navbar__user-name" title={@scope.identity.email}>
        <.icon name="hero-user-circle" class="size-4" />{Identity.label(@scope.identity)}
      </span>
      <span :if={primary_role(@scope)} class="chip">{primary_role(@scope)}</span>
      <.link href={~p"/auth/logout"} class="navlink" title={gettext("Sign out")}>
        <.icon name="hero-arrow-left-on-rectangle" class="size-4" />
        <span class="sr-only">{gettext("Sign out")}</span>
      </.link>
    </div>
    """
  end

  # The most privileged recognised role, so the chip reads "admin" rather than
  # whichever role happened to sort first on the token.
  defp primary_role(scope) do
    Enum.find(Identity.known_roles(), &Scope.has_role?(scope, &1))
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="toast" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="themetoggle" role="group" aria-label={gettext("Color theme")}>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop" class="size-4" />
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
      >
        <.icon name="hero-sun" class="size-4" />
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
      >
        <.icon name="hero-moon" class="size-4" />
      </button>
    </div>
    """
  end
end
