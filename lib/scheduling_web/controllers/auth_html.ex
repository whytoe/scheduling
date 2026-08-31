defmodule SchedulingWeb.AuthHTML do
  @moduledoc """
  The pages a signed-out or under-privileged operator can land on.

  All render as self-contained documents rather than through
  `SchedulingWeb.Layouts.app/1`: the app layout's navbar links to eight
  screens the viewer cannot open, which reads as a broken app rather than a
  closed door.

  `signed_out/1` and `forbidden/1` reuse the `errpage` pattern from the styled
  404/500 pages, so the whole "you can't get there" family looks like one
  thing. `login/1` deliberately does **not**: it is the front door, not a
  closed one, and dressing it in the error furniture would tell an operator
  starting their shift that something has gone wrong. It shares the document
  shell and the tokens, and nothing else.
  """
  use SchedulingWeb, :html

  @doc """
  The sign-in page.

  One route in, so there is one button. This deployment has no local password
  — identity comes from the organisation's provider — and offering an empty
  credential form beside the only control that works would just invite people
  to try their EMR password against it.
  """
  def login(assigns) do
    ~H"""
    <.auth_document title={gettext("Sign in")}>
      <main class="app grid place-items-center">
        <div class="loginpage">
          <div class="loginpage__brand">
            <span class="loginpage__mark"><.icon name="hero-calendar-days" class="size-5" /></span>
            <span class="loginpage__word">{gettext("Scheduling")}</span>
          </div>

          <h1 class="loginpage__title">{gettext("Sign in")}</h1>
          <p class="loginpage__body">
            {gettext("Use your organisation account to continue.")}
          </p>

          <p :if={flash_message(@flash)} class="loginpage__alert" role="alert">
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
            <span>{flash_message(@flash)}</span>
          </p>

          <a href={~p"/auth/start"} class="btn btn-primary loginpage__cta">
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
            {gettext("Login with Astrum SSO")}
          </a>

          <p class="loginpage__note">
            {gettext("You will be taken to your provider to sign in, then returned here.")}
          </p>
        </div>
      </main>
    </.auth_document>
    """
  end

  @doc """
  Landing page after logout, and the destination for a failed or
  role-less sign-in. The reason arrives as a flash from
  `SchedulingWeb.AuthController`.
  """
  def signed_out(assigns) do
    ~H"""
    <.auth_page title={gettext("Signed out")} icon="hero-lock-closed" tone="neutral">
      <:message>
        {flash_message(@flash) ||
          gettext("You are signed out. Sign in with your organisation account to continue.")}
      </:message>
      <a href={~p"/auth/login"} class="btn btn-primary">
        <.icon name="hero-arrow-right-on-rectangle" class="size-4" />{gettext("Sign in")}
      </a>
    </.auth_page>
    """
  end

  @doc """
  Rendered by `SchedulingWeb.Plugs.BrowserAuth.require_role/2` — the operator
  is signed in, but not for this. Naming the required role turns "access
  denied" into something an administrator can act on.
  """
  def forbidden(assigns) do
    ~H"""
    <.auth_page title={gettext("Not permitted")} icon="hero-no-symbol" tone="attention">
      <:message>
        {gettext(
          "Your account does not have access to this screen. It requires the %{roles} role.",
          roles: Enum.join(@roles, gettext(" or "))
        )}
      </:message>
      <a href={~p"/board"} class="btn btn-primary">
        <.icon name="hero-squares-2x2" class="size-4" />{gettext("Back to board")}
      </a>
      <a href={~p"/auth/logout"} class="btn btn-ghost">
        <.icon name="hero-arrow-left-on-rectangle" class="size-4" />{gettext("Sign out")}
      </a>
    </.auth_page>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true
  slot :message, required: true
  slot :inner_block, required: true

  defp auth_page(assigns) do
    ~H"""
    <.auth_document title={@title}>
      <main class="app grid place-items-center">
        <div class="errpage">
          <div class={["errpage__glyph", @tone]}><.icon name={@icon} class="size-[30px]" /></div>
          <h1 class="errpage__title">{@title}</h1>
          <p class="errpage__body">{render_slot(@message)}</p>
          <div class="errpage__actions">{render_slot(@inner_block)}</div>
        </div>
      </main>
    </.auth_document>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  # The shell every page here shares. These render outside the app layout, so
  # each one needs its own head; keeping that in one place is what stops the
  # font links and stylesheet drifting apart between them.
  defp auth_document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Scheduling</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Public+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body>
        {render_slot(@inner_block)}
      </body>
    </html>
    """
  end

  # Either flash key can carry the reason; :error wins because a failed
  # sign-in is more urgent than the routine "you are signed out".
  defp flash_message(flash) do
    Phoenix.Flash.get(flash, :error) || Phoenix.Flash.get(flash, :info)
  end
end
