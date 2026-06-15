defmodule SchedulingWeb.CapabilityLive.Index do
  @moduledoc """
  CRUD for the capability catalog — the labels (XRay, CT Scan, Dialysis…)
  offices declare they can provide and queue entries can require. Presented as a
  searchable card grid (designed to stay legible at ~50 entries) with the shared
  inline edit form and a delete confirmation dialog.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Catalog
  alias Scheduling.Catalog.Capability

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:confirm, nil)
     |> assign(:capabilities, Catalog.list_capabilities())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Capabilities")
    |> assign(:capability, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    capability = %Capability{}

    socket
    |> assign(:page_title, "New capability")
    |> assign(:capability, capability)
    |> assign_form(Catalog.change_capability(capability))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    capability = Catalog.get_capability!(id)

    socket
    |> assign(:page_title, "Edit #{capability.name}")
    |> assign(:capability, capability)
    |> assign_form(Catalog.change_capability(capability))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :query, q)}
  end

  def handle_event("validate", %{"capability" => params}, socket) do
    changeset = Catalog.change_capability(socket.assigns.capability, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"capability" => params}, socket) do
    save_capability(socket, socket.assigns.live_action, params)
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    capability = Catalog.get_capability!(id)
    {:noreply, assign(socket, :confirm, %{id: capability.id, name: capability.name})}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    capability = Catalog.get_capability!(id)
    {:ok, _} = Catalog.delete_capability(capability)

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> put_flash(:info, "Deleted #{capability.name}.")
     |> assign(:capabilities, Catalog.list_capabilities())}
  end

  defp save_capability(socket, :new, params) do
    case Catalog.create_capability(params) do
      {:ok, _capability} ->
        {:noreply,
         socket
         |> put_flash(:info, "Capability created")
         |> assign(:capabilities, Catalog.list_capabilities())
         |> push_patch(to: ~p"/capabilities")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_capability(socket, :edit, params) do
    case Catalog.update_capability(socket.assigns.capability, params) do
      {:ok, _capability} ->
        {:noreply,
         socket
         |> put_flash(:info, "Capability updated")
         |> assign(:capabilities, Catalog.list_capabilities())
         |> push_patch(to: ~p"/capabilities")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp filtered(capabilities, query) do
    q = query |> to_string() |> String.downcase() |> String.trim()

    if q == "",
      do: capabilities,
      else: Enum.filter(capabilities, &String.contains?(String.downcase(&1.name), q))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rows, filtered(assigns.capabilities, assigns.query))

    ~H"""
    <Layouts.app flash={@flash} active={:capabilities}>
      <.page_head title="Capabilities">
        <:subtitle>
          The catalog every office and diagnosis draws from. The layout is built to stay
          legible as it grows.
        </:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/capabilities/new"}>
            <.icon name="hero-plus" class="size-4" />New capability
          </.button>
        </:actions>
      </.page_head>

      <.capability_form :if={@live_action in [:new, :edit]} form={@form} page_title={@page_title} />

      <form phx-change="search" class="relative max-w-[320px]" style="margin-bottom:var(--s-4)">
        <.icon
          name="hero-magnifying-glass"
          class="size-4 absolute left-3 top-3 text-base-content/50 pointer-events-none"
        />
        <input
          type="text"
          name="q"
          value={@query}
          phx-debounce="200"
          class="input"
          style="padding-left:36px"
          placeholder={"Search #{length(@capabilities)} capabilities…"}
          aria-label="Search capabilities"
        />
      </form>

      <div :if={@rows == []} class="card">
        <.empty_state icon="hero-beaker" title="No capabilities match">
          Nothing matches your search. Clear it or add a new capability.
        </.empty_state>
      </div>

      <div :if={@rows != []} class="grid-cards grid-cards--auto">
        <div
          :for={cap <- @rows}
          class="card card__body flex items-center justify-between gap-2"
        >
          <span class="flex items-center gap-2 font-medium min-w-0">
            <.icon name="hero-beaker" class="size-4 text-base-content/50 shrink-0" />
            <span class="truncate">{cap.name}</span>
          </span>
          <div class="table__actions">
            <.link
              navigate={~p"/capabilities/#{cap}/edit"}
              class="btn btn-ghost btn-sm"
              aria-label={"Edit #{cap.name}"}
            >
              <.icon name="hero-pencil-square" class="size-[15px]" />
            </.link>
            <button
              type="button"
              class="btn btn-danger btn-sm"
              aria-label={"Delete #{cap.name}"}
              phx-click={JS.push("confirm_delete", value: %{id: cap.id})}
            >
              <.icon name="hero-trash" class="size-[15px]" />
            </button>
          </div>
        </div>
      </div>

      <.confirm_dialog
        id="delete-capability"
        show={@confirm != nil}
        title="Delete this capability?"
        confirm_label="Delete capability"
        on_confirm={@confirm && JS.push("delete", value: %{id: @confirm.id})}
        on_cancel={JS.push("cancel_delete")}
      >
        <span :if={@confirm}>
          <b>{@confirm.name}</b>
          will be removed from the catalog. Offices and diagnoses that reference it lose the
          requirement. This cannot be undone.
        </span>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :page_title, :string, required: true

  defp capability_form(assigns) do
    ~H"""
    <div class="editform">
      <div class="editform__title">
        <.icon name="hero-pencil-square" class="size-[18px]" />{@page_title}
      </div>

      <.form for={@form} id="capability-form" phx-change="validate" phx-submit="save">
        <div class="field">
          <label class="field__label" for="capability_name">Name</label>
          <input
            type="text"
            id="capability_name"
            name="capability[name]"
            value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
            class="input"
            placeholder="e.g. Audiology"
          />
          <div class="field__hint">
            Short, unique. Used as a chip across offices, diagnoses and the queue.
          </div>
          <.field_errors field={@form[:name]} />
        </div>

        <div class="field">
          <label class="field__label" for="capability_description">Description</label>
          <input
            type="text"
            id="capability_description"
            name="capability[description]"
            value={Phoenix.HTML.Form.normalize_value("text", @form[:description].value)}
            class="input"
            placeholder="Optional"
          />
          <.field_errors field={@form[:description]} />
        </div>

        <div class="flex gap-2">
          <.button variant="primary" type="submit">Save capability</.button>
          <.button variant="ghost" navigate={~p"/capabilities"}>Cancel</.button>
        </div>
      </.form>
    </div>
    """
  end
end
