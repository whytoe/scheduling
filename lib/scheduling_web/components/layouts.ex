defmodule SchedulingWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SchedulingWeb, :html

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
      "the active nav tab — one of :board, :queue, :decisions, :visit_events, :visits, :offices, :capabilities, :diagnoses"

  attr :wide, :boolean, default: false, doc: "use the wider page container"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  @nav [
    {:board, "Board", "hero-squares-2x2", "/board"},
    {:queue, "Queue", "hero-queue-list", "/queue"},
    {:decisions, "Decisions", "hero-document-magnifying-glass", "/decisions"},
    {:visit_events, "Visit events", "hero-clock", "/visit_events"},
    {:visits, "Visits", "hero-rectangle-stack", "/visits"},
    {:offices, "Offices", "hero-building-office", "/offices"},
    {:capabilities, "Capabilities", "hero-beaker", "/capabilities"},
    {:diagnoses, "Diagnoses", "hero-clipboard-document-list", "/diagnoses"}
  ]

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <div class="app">
      <header class="appnav">
        <.link navigate={~p"/board"} class="navbar__brand">
          <span class="navbar__logo"><.icon name="hero-squares-2x2" class="size-[17px]" /></span>
          <span class="navbar__title">Scheduling</span>
        </.link>
        <nav class="navbar__nav" aria-label={gettext("Primary")}>
          <.link
            :for={{id, label, icon, path} <- @nav}
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
        <.theme_toggle />
      </header>

      <main class={["page", @wide && "page--wide"]}>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
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
    <div id={@id} aria-live="polite">
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
