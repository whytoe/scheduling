defmodule SchedulingWeb.AuthHTML do
  @moduledoc """
  The two pages a signed-out or under-privileged operator can land on.

  Both render as self-contained documents rather than through
  `SchedulingWeb.Layouts.app/1`: the app layout's navbar links to eight
  screens the viewer cannot open, which reads as a broken app rather than a
  closed door. They reuse the `errpage` pattern from the styled 404/500 pages
  so the whole "you can't get there" family looks like one thing.
  """
  use SchedulingWeb, :html

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
        <main class="app grid place-items-center">
          <div class="errpage">
            <div class={["errpage__glyph", @tone]}><.icon name={@icon} class="size-[30px]" /></div>
            <h1 class="errpage__title">{@title}</h1>
            <p class="errpage__body">{render_slot(@message)}</p>
            <div class="errpage__actions">{render_slot(@inner_block)}</div>
          </div>
        </main>
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
