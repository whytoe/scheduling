defmodule SchedulingWeb.OfficeLive.Index do
  @moduledoc """
  CRUD for offices. The "form above table" pattern: one elevated panel with an
  indigo left edge that reads blank for **new** and pre-filled for **edit**.
  Delete routes through a confirmation dialog that names the exact consequence.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Catalog
  alias Scheduling.Offices
  alias Scheduling.Offices.Office

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:capabilities, Catalog.list_capabilities())
     |> assign(:confirm, nil)
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
    |> assign(:page_title, "New office")
    |> assign(:office, office)
    |> assign_form(Offices.change_office(office))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    office = Offices.get_office!(id)

    socket
    |> assign(:page_title, "Edit #{office.name}")
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

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    office = Offices.get_office!(id)
    {:noreply, assign(socket, :confirm, %{id: office.id, name: office.name})}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    office = Offices.get_office!(id)
    {:ok, _} = Offices.delete_office(office)

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> put_flash(:info, "Deleted #{office.name}.")
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

  defp capability_list(office) do
    office.capabilities |> Enum.map(& &1.name) |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:offices}>
      <.page_head title="Offices">
        <:subtitle>Configure each office's intake capacity and capabilities.</:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/offices/new"}>
            <.icon name="hero-plus" class="size-4" />New office
          </.button>
        </:actions>
      </.page_head>

      <.office_form
        :if={@live_action in [:new, :edit]}
        form={@form}
        page_title={@page_title}
        capabilities={@capabilities}
        selected_capability_ids={@selected_capability_ids}
      />

      <div class="card overflow-hidden" style="padding:0">
        <table class="table">
          <thead>
            <tr>
              <th>Office</th>
              <th style="width:110px">Capacity</th>
              <th>Capabilities</th>
              <th style="width:1px"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="offices" phx-update="stream">
            <tr :for={{dom_id, office} <- @streams.offices} id={dom_id}>
              <td class="font-semibold">{office.name}</td>
              <td class="tnum">{office.intake_capacity}</td>
              <td><.cap_row caps={capability_list(office)} /></td>
              <td>
                <div class="table__actions">
                  <.link
                    navigate={~p"/offices/#{office}/edit"}
                    class="btn btn-ghost btn-sm"
                    aria-label={"Edit #{office.name}"}
                  >
                    <.icon name="hero-pencil-square" class="size-[15px]" />
                  </.link>
                  <button
                    type="button"
                    class="btn btn-danger btn-sm"
                    aria-label={"Delete #{office.name}"}
                    phx-click={JS.push("confirm_delete", value: %{id: office.id})}
                  >
                    <.icon name="hero-trash" class="size-[15px]" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.confirm_dialog
        id="delete-office"
        show={@confirm != nil}
        title="Delete this office?"
        confirm_label="Delete office"
        on_confirm={@confirm && JS.push("delete", value: %{id: @confirm.id})}
        on_cancel={JS.push("cancel_delete")}
      >
        <span :if={@confirm}>
          <b>{@confirm.name}</b>
          will be removed. Patients currently routed here keep their assignment, but no new
          patients can be matched to it. This cannot be undone.
        </span>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :page_title, :string, required: true
  attr :capabilities, :list, required: true
  attr :selected_capability_ids, :list, required: true

  defp office_form(assigns) do
    ~H"""
    <div class="editform">
      <div class="editform__title">
        <.icon name="hero-pencil-square" class="size-[18px]" />{@page_title}
      </div>

      <.form for={@form} id="office-form" phx-change="validate" phx-submit="save">
        <div class="cols cols--2" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="office_name">Name</label>
            <input
              type="text"
              id="office_name"
              name="office[name]"
              value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
              class="input"
              placeholder="e.g. Room 6 · Dermatology"
            />
            <.field_errors field={@form[:name]} />
          </div>
          <div class="field">
            <label class="field__label" for="office_intake_capacity">Intake capacity</label>
            <input
              type="number"
              min="0"
              id="office_intake_capacity"
              name="office[intake_capacity]"
              value={Phoenix.HTML.Form.normalize_value("number", @form[:intake_capacity].value)}
              class="input tnum"
            />
            <div class="field__hint">How many patients this office can serve at once.</div>
            <.field_errors field={@form[:intake_capacity]} />
          </div>
        </div>

        <div class="field">
          <label class="field__label">Capabilities</label>
          <input type="hidden" name="office[capability_ids][]" value="" />
          <div class="checkboxgrid">
            <label
              :for={cap <- @capabilities}
              class={["checkrow", cap.id in @selected_capability_ids && "checkrow--on"]}
            >
              <input
                type="checkbox"
                name="office[capability_ids][]"
                value={cap.id}
                checked={cap.id in @selected_capability_ids}
              />
              {cap.name}
            </label>
          </div>
          <div class="field__hint">{length(@selected_capability_ids)} selected</div>
        </div>

        <div class="flex gap-2" style="margin-top:var(--s-4)">
          <.button variant="primary" type="submit">Save office</.button>
          <.button variant="ghost" navigate={~p"/offices"}>Cancel</.button>
        </div>
      </.form>
    </div>
    """
  end
end
