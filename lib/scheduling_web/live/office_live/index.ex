defmodule SchedulingWeb.OfficeLive.Index do
  use SchedulingWeb, :live_view

  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Offices.Office

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:capabilities, Catalog.list_capabilities())
     |> stream(:offices, Offices.list_offices())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Offices")
    |> assign(:office, nil)
    |> assign(:form, nil)
    |> assign(:selected_capability_ids, [])
  end

  defp apply_action(socket, :new, _params) do
    office = %Office{capabilities: []}

    socket
    |> assign(:page_title, "New Office")
    |> assign(:office, office)
    |> assign_form(Offices.change_office(office))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    office = Offices.get_office!(id)

    socket
    |> assign(:page_title, "Edit Office")
    |> assign(:office, office)
    |> assign_form(Offices.change_office(office))
  end

  @impl true
  def handle_event("validate", %{"office" => office_params}, socket) do
    changeset = Offices.change_office(socket.assigns.office, office_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"office" => office_params}, socket) do
    save_office(socket, socket.assigns.live_action, office_params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    office = Offices.get_office!(id)
    {:ok, _} = Offices.delete_office(office)

    {:noreply,
     socket
     |> put_flash(:info, "Office deleted")
     |> stream_delete(:offices, office)}
  end

  defp save_office(socket, :new, office_params) do
    case Offices.create_office(office_params) do
      {:ok, office} ->
        {:noreply,
         socket
         |> put_flash(:info, "Office created")
         |> stream_insert(:offices, with_capabilities(office))
         |> push_patch(to: ~p"/offices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_office(socket, :edit, office_params) do
    case Offices.update_office(socket.assigns.office, office_params) do
      {:ok, office} ->
        {:noreply,
         socket
         |> put_flash(:info, "Office updated")
         |> stream_insert(:offices, with_capabilities(office))
         |> push_patch(to: ~p"/offices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    selected =
      changeset
      |> Ecto.Changeset.get_field(:capabilities, [])
      |> Enum.map(& &1.id)

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:selected_capability_ids, selected)
  end

  defp with_capabilities(%Office{} = office) do
    Scheduling.Repo.preload(office, :capabilities, force: true)
  end

  defp capability_names(office) do
    office.capabilities
    |> Enum.map(& &1.name)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Offices
        <:subtitle>Configure each office's intake capacity and capabilities.</:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/offices/new"}>New Office</.button>
        </:actions>
      </.header>

      <.office_form
        :if={@live_action in [:new, :edit]}
        form={@form}
        page_title={@page_title}
        capabilities={@capabilities}
        selected_capability_ids={@selected_capability_ids}
      />

      <.table id="offices" rows={@streams.offices}>
        <:col :let={{_id, office}} label="Name">{office.name}</:col>
        <:col :let={{_id, office}} label="Intake capacity">{office.intake_capacity}</:col>
        <:col :let={{_id, office}} label="Capabilities">
          {capability_names(office)}
        </:col>
        <:action :let={{_id, office}}>
          <.link navigate={~p"/offices/#{office}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, office}}>
          <.link
            phx-click={JS.push("delete", value: %{id: office.id}) |> hide("##{id}")}
            data-confirm="Delete this office?"
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
  attr :capabilities, :list, required: true
  attr :selected_capability_ids, :list, required: true

  defp office_form(assigns) do
    ~H"""
    <div class="mt-4 mb-8 border-b pb-6">
      <.header>{@page_title}</.header>

      <.form for={@form} id="office-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:intake_capacity]} type="number" label="Intake capacity" min="0" />

        <fieldset class="fieldset mb-4">
          <legend class="label">Capabilities</legend>
          <input type="hidden" name="office[capability_ids][]" value="" />
          <label :for={cap <- @capabilities} class="flex items-center gap-2">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              name="office[capability_ids][]"
              value={cap.id}
              checked={cap.id in @selected_capability_ids}
            />
            {cap.name}
          </label>
        </fieldset>

        <div class="flex gap-2">
          <.button variant="primary" type="submit">Save Office</.button>
          <.button navigate={~p"/offices"}>Cancel</.button>
        </div>
      </.form>
    </div>
    """
  end
end
