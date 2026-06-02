defmodule SchedulingWeb.CapabilityLive.Index do
  @moduledoc """
  CRUD for the capability catalog — the labels (XRay, CT Scan, Dialysis…)
  offices declare they can provide and queue entries can require.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Catalog
  alias Scheduling.Catalog.Capability

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :capabilities, Catalog.list_capabilities())}
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
    |> assign(:page_title, "New Capability")
    |> assign(:capability, capability)
    |> assign_form(Catalog.change_capability(capability))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    capability = Catalog.get_capability!(id)

    socket
    |> assign(:page_title, "Edit Capability")
    |> assign(:capability, capability)
    |> assign_form(Catalog.change_capability(capability))
  end

  @impl true
  def handle_event("validate", %{"capability" => params}, socket) do
    changeset = Catalog.change_capability(socket.assigns.capability, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"capability" => params}, socket) do
    save_capability(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    capability = Catalog.get_capability!(id)
    {:ok, _} = Catalog.delete_capability(capability)

    {:noreply,
     socket
     |> put_flash(:info, "Capability deleted")
     |> stream_delete(:capabilities, capability)}
  end

  defp save_capability(socket, :new, params) do
    case Catalog.create_capability(params) do
      {:ok, capability} ->
        {:noreply,
         socket
         |> put_flash(:info, "Capability created")
         |> stream_insert(:capabilities, capability)
         |> push_patch(to: ~p"/capabilities")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_capability(socket, :edit, params) do
    case Catalog.update_capability(socket.assigns.capability, params) do
      {:ok, capability} ->
        {:noreply,
         socket
         |> put_flash(:info, "Capability updated")
         |> stream_insert(:capabilities, capability)
         |> push_patch(to: ~p"/capabilities")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Capabilities
        <:subtitle>
          The labels offices can provide and patients can require — e.g. XRay,
          CT Scan, Dialysis. Add, rename, or remove them here.
        </:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/capabilities/new"}>New Capability</.button>
        </:actions>
      </.header>

      <.capability_form
        :if={@live_action in [:new, :edit]}
        form={@form}
        page_title={@page_title}
      />

      <.table id="capabilities" rows={@streams.capabilities}>
        <:col :let={{_id, capability}} label="Name">{capability.name}</:col>
        <:col :let={{_id, capability}} label="Description">
          {capability.description}
        </:col>
        <:action :let={{_id, capability}}>
          <.link navigate={~p"/capabilities/#{capability}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, capability}}>
          <.link
            phx-click={JS.push("delete", value: %{id: capability.id}) |> hide("##{id}")}
            data-confirm="Delete this capability? It will be removed from every office, diagnosis default, and pending queue requirement that referenced it."
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :page_title, :string, required: true

  defp capability_form(assigns) do
    ~H"""
    <div class="mt-4 mb-8 border-b pb-6">
      <.header>{@page_title}</.header>

      <.form for={@form} id="capability-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:description]} type="text" label="Description" />

        <div class="flex gap-2">
          <.button variant="primary" type="submit">Save Capability</.button>
          <.button navigate={~p"/capabilities"}>Cancel</.button>
        </div>
      </.form>
    </div>
    """
  end
end
