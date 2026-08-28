defmodule SchedulingWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages (404 / 500). Calm, centered, reduced-motion-safe.
  The 500 page reassures that the board keeps running and data is safe, and
  shows a support reference id. Both offer a path back to the board. Copy is
  translation-friendly (no idioms).

  These render as self-contained documents (errors bypass the app layout), so
  each links the app stylesheet and the fonts directly.
  """
  use SchedulingWeb, :html

  def render("404.html", assigns) do
    ~H"""
    <.error_page
      code="Error 404"
      tone="neutral"
      icon="hero-magnifying-glass"
      title={gettext("Page not found")}
    >
      {gettext("That page does not exist or has moved. Check the address, or return to the board.")}
    </.error_page>
    """
  end

  def render("500.html", assigns) do
    assigns = Map.put(assigns, :ref, request_ref(assigns))

    ~H"""
    <.error_page
      code="Error 500"
      tone="attention"
      icon="hero-exclamation-triangle"
      title={gettext("Something went wrong")}
      ref={@ref}
      reload
    >
      {gettext(
        "An unexpected error occurred on our end. The board keeps running and your data is safe. Try again, or return to the board."
      )}
    </.error_page>
    """
  end

  # Any other template (e.g. 400, 503) falls back to its plain status message.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  attr :code, :string, required: true
  attr :tone, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :ref, :string, default: nil
  attr :reload, :boolean, default: false
  slot :inner_block, required: true

  defp error_page(assigns) do
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
          <div class="errpage" role="alert">
            <div class={["errpage__glyph", @tone]}><.icon name={@icon} class="size-[30px]" /></div>
            <div class="errpage__code">{@code}</div>
            <h1 class="errpage__title">{@title}</h1>
            <p class="errpage__body">{render_slot(@inner_block)}</p>
            <div :if={@ref} class="errpage__ref">
              {gettext("Reference:")} {@ref} · {gettext("share with support")}
            </div>
            <div class="errpage__actions">
              <a :if={@reload} href={~p"/board"} class="btn btn-ghost">
                <.icon name="hero-arrow-path" class="size-4" />{gettext("Try again")}
              </a>
              <a href={~p"/board"} class="btn btn-primary">
                <.icon name="hero-squares-2x2" class="size-4" />{gettext("Back to board")}
              </a>
            </div>
          </div>
        </main>
      </body>
    </html>
    """
  end

  defp request_ref(assigns) do
    case assigns[:conn] do
      %Plug.Conn{} = conn ->
        case Plug.Conn.get_resp_header(conn, "x-request-id") do
          [id | _] when is_binary(id) and id != "" -> id
          _ -> Logger.metadata()[:request_id]
        end

      _ ->
        Logger.metadata()[:request_id]
    end
  end
end
