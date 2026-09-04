defmodule SchedulingWeb.DiagnosisLive.Index do
  @moduledoc """
  CRUD for the diagnosis catalog. Each diagnosis carries default required
  capabilities and a set of **compliance references** — opaque identifiers
  minted by intakeform, one per form type, which an admin reads from
  `GET /api/v1/forms` and pastes here.

  As the operator types, a value that does not look like a reference is flagged
  with an amber callout. This used to be the other way round: the field held
  form-type names and we warned when one matched a known-sensitive class
  (PHQ-9, GAD-7, HIV consent, …). That required scheduling to carry a
  vocabulary of clinical form names in its own source, and it only caught the
  classes we had thought of.

  Inverting it is strictly better. Scheduling cannot tell what a reference
  means — that is the point — so instead of guessing which names are sensitive
  we flag anything that is *not* a reference. A form name entered here now
  fails the check by construction rather than by matching a list.

  It informs rather than blocks: the reference format is intake's to change,
  and a hard rule here would break the catalog the day they change it.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Catalog
  alias Scheduling.Catalog.Diagnosis

  # Intake mints these as a `cref_` prefix followed by random hex — random, not
  # derived from the form-type name, so they cannot be reversed by guessing.
  # Matched loosely on purpose: this is a nudge, not validation.
  @reference_pattern ~r/^cref_[a-z0-9]{8,}$/i

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:capabilities, Catalog.list_capabilities())
     |> assign(:confirm, nil)
     |> assign(:diagnoses, Catalog.list_diagnoses())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Diagnoses")
    |> assign(:diagnosis, nil)
    |> assign(:form, nil)
    |> assign(:selected_capability_ids, [])
    |> assign(:form_types, [])
    |> assign(:draft, "")
    |> assign(:draft_unreferenced, false)
  end

  defp apply_action(socket, :new, _params) do
    diagnosis = %Diagnosis{capabilities: []}

    socket
    |> assign(:page_title, "New diagnosis")
    |> assign(:diagnosis, diagnosis)
    |> assign(:form_types, [])
    |> assign(:draft, "")
    |> assign(:draft_unreferenced, false)
    |> assign_form(Catalog.change_diagnosis(diagnosis))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    diagnosis = Catalog.get_diagnosis!(id)

    socket
    |> assign(:page_title, "Edit #{diagnosis.name}")
    |> assign(:diagnosis, diagnosis)
    |> assign(:form_types, diagnosis.required_compliance_refs || [])
    |> assign(:draft, "")
    |> assign(:draft_unreferenced, false)
    |> assign_form(Catalog.change_diagnosis(diagnosis))
  end

  @impl true
  def handle_event("validate", %{"diagnosis" => params}, socket) do
    changeset = Catalog.change_diagnosis(socket.assigns.diagnosis, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("type_form", %{"draft" => draft}, socket) do
    {:noreply, assign(socket, draft: draft, draft_unreferenced: not_a_reference?(draft))}
  end

  def handle_event("add_form", %{"draft" => draft}, socket) do
    value = String.trim(draft)
    types = socket.assigns.form_types

    types = if value != "" and value not in types, do: types ++ [value], else: types

    {:noreply, assign(socket, form_types: types, draft: "", draft_unreferenced: false)}
  end

  def handle_event("remove_form", %{"form" => form}, socket) do
    {:noreply, assign(socket, :form_types, socket.assigns.form_types -- [form])}
  end

  def handle_event("save", %{"diagnosis" => params}, socket) do
    params = Map.put(params, "required_compliance_refs", socket.assigns.form_types)
    save_diagnosis(socket, socket.assigns.live_action, params)
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    diagnosis = Catalog.get_diagnosis!(id)
    {:noreply, assign(socket, :confirm, %{id: diagnosis.id, name: diagnosis.name})}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    diagnosis = Catalog.get_diagnosis!(id)
    {:ok, _} = Catalog.delete_diagnosis(diagnosis)

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> put_flash(:info, "Deleted #{diagnosis.name}.")
     |> assign(:diagnoses, Catalog.list_diagnoses())}
  end

  defp save_diagnosis(socket, :new, params) do
    case Catalog.create_diagnosis(params) do
      {:ok, _diagnosis} ->
        {:noreply,
         socket
         |> put_flash(:info, "Diagnosis created")
         |> assign(:diagnoses, Catalog.list_diagnoses())
         |> push_patch(to: ~p"/diagnoses")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_diagnosis(socket, :edit, params) do
    case Catalog.update_diagnosis(socket.assigns.diagnosis, params) do
      {:ok, _diagnosis} ->
        {:noreply,
         socket
         |> put_flash(:info, "Diagnosis updated")
         |> assign(:diagnoses, Catalog.list_diagnoses())
         |> push_patch(to: ~p"/diagnoses")}

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

  @doc """
  True when a value does not look like an intakeform compliance reference.

  Named for what it flags rather than what it accepts, because the flag is the
  interesting state: a bare form name is the mistake this catches, and a form
  name bound to a diagnosis is precisely the clinical content scheduling must
  not store.
  """
  def not_a_reference?(value) do
    v = value |> to_string() |> String.trim()
    v != "" and not Regex.match?(@reference_pattern, v)
  end

  defp capability_list(diagnosis) do
    diagnosis.capabilities |> Enum.map(& &1.name) |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:diagnoses}>
      <.page_head title="Diagnoses">
        <:subtitle>
          Each diagnosis carries default required capabilities and required form types.
          Sensitive form types are flagged inline as you type.
        </:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/diagnoses/new"}>
            <.icon name="hero-plus" class="size-4" />New diagnosis
          </.button>
        </:actions>
      </.page_head>

      <.diagnosis_form
        :if={@live_action in [:new, :edit]}
        form={@form}
        page_title={@page_title}
        capabilities={@capabilities}
        selected_capability_ids={@selected_capability_ids}
        form_types={@form_types}
        draft={@draft}
        draft_unreferenced={@draft_unreferenced}
      />

      <div :if={@diagnoses == []} class="card">
        <.empty_state icon="hero-clipboard-document-list" title="No diagnoses yet">
          Add a diagnosis to define its default capabilities and required forms.
        </.empty_state>
      </div>

      <div :if={@diagnoses != []} class="card overflow-hidden" style="padding:0">
        <table class="table">
          <thead>
            <tr>
              <th>Diagnosis</th>
              <th style="width:100px">Code</th>
              <th>Capabilities</th>
              <th>Form types</th>
              <th style="width:1px"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={d <- @diagnoses}>
              <td class="font-semibold">{d.name}</td>
              <td class="mono t-small">{d.code}</td>
              <td><.cap_row caps={capability_list(d)} /></td>
              <td>
                <span class="chiprow">
                  <span
                    :for={f <- d.required_compliance_refs || []}
                    class={["badge", (not_a_reference?(f) && "attention") || "neutral"]}
                    title={(not_a_reference?(f) && "Sensitive form type") || nil}
                  >
                    <.icon :if={not_a_reference?(f)} name="hero-eye-slash" class="size-[12px]" />
                    <span class="mono" style="font-size:12px">{f}</span>
                  </span>
                </span>
              </td>
              <td>
                <div class="table__actions">
                  <.link
                    navigate={~p"/diagnoses/#{d}/edit"}
                    class="btn btn-ghost btn-sm"
                    aria-label={"Edit #{d.name}"}
                  >
                    <.icon name="hero-pencil-square" class="size-[15px]" />
                  </.link>
                  <button
                    type="button"
                    class="btn btn-danger btn-sm"
                    aria-label={"Delete #{d.name}"}
                    phx-click={JS.push("confirm_delete", value: %{id: d.id})}
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
        id="delete-diagnosis"
        show={@confirm != nil}
        title="Delete this diagnosis?"
        confirm_label="Delete diagnosis"
        on_confirm={@confirm && JS.push("delete", value: %{id: @confirm.id})}
        on_cancel={JS.push("cancel_delete")}
      >
        <span :if={@confirm}>
          <b>{@confirm.name}</b>
          and its default capability + form-type mapping will be removed. Existing queue
          entries keep the requirements they already inherited. This cannot be undone.
        </span>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :page_title, :string, required: true
  attr :capabilities, :list, required: true
  attr :selected_capability_ids, :list, required: true
  attr :form_types, :list, required: true
  attr :draft, :string, required: true
  attr :draft_unreferenced, :boolean, required: true

  defp diagnosis_form(assigns) do
    assigns =
      assign(
        assigns,
        :unreferenced_selected,
        Enum.filter(assigns.form_types, &not_a_reference?/1)
      )

    ~H"""
    <div class="editform">
      <div class="editform__title">
        <.icon name="hero-pencil-square" class="size-[18px]" />{@page_title}
      </div>

      <.form for={@form} id="diagnosis-form" phx-change="validate" phx-submit="save">
        <div class="cols cols--2" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="diagnosis_name">Name</label>
            <input
              type="text"
              id="diagnosis_name"
              name="diagnosis[name]"
              value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
              class="input"
              placeholder="e.g. Counselling intake"
            />
            <.field_errors field={@form[:name]} />
          </div>
          <div class="field">
            <label class="field__label" for="diagnosis_code">Code</label>
            <input
              type="text"
              id="diagnosis_code"
              name="diagnosis[code]"
              value={Phoenix.HTML.Form.normalize_value("text", @form[:code].value)}
              class="input mono"
              placeholder="e.g. Z71.9"
            />
            <div class="field__hint">ICD-10</div>
            <.field_errors field={@form[:code]} />
          </div>
        </div>

        <div class="field">
          <label class="field__label">Default required capabilities</label>
          <input type="hidden" name="diagnosis[capability_ids][]" value="" />
          <div class="checkboxgrid">
            <label
              :for={cap <- @capabilities}
              class={["checkrow", cap.id in @selected_capability_ids && "checkrow--on"]}
            >
              <input
                type="checkbox"
                name="diagnosis[capability_ids][]"
                value={cap.id}
                checked={cap.id in @selected_capability_ids}
              />
              {cap.name}
            </label>
          </div>
        </div>
      </.form>

      <%!-- Required form types: type-to-add chips with live sensitive detection.
            Kept in its own form so Enter adds a chip instead of saving. --%>
      <div class="field">
        <label class="field__label" for="form-draft">Required form types</label>
        <form phx-change="type_form" phx-submit="add_form" class="flex gap-2">
          <input
            type="text"
            id="form-draft"
            name="draft"
            value={@draft}
            phx-debounce="120"
            class={["input mono flex-1", @draft_unreferenced && "input--error"]}
            placeholder="e.g. cref_7f3a91c4e2b8"
            autocomplete="off"
            aria-describedby={(@draft_unreferenced && "sens-warn") || nil}
          />
          <.button variant="subtle" type="submit">Add</.button>
        </form>
        <div class="field__hint">
          Press Enter to add. Paste the reference from intakeform, not the form's name.
        </div>

        <div :if={@draft_unreferenced} id="sens-warn" style="margin-top:var(--s-2)">
          <.callout
            tone="attention"
            icon="hero-exclamation-triangle"
            title={~s["#{String.trim(@draft)}" is not a compliance reference]}
          >
            References come from intakeform and look like <code>cref_7f3a91c4e2b8</code>.
            A form's name entered here is clinical content, which this system does not
            carry — and intake will not recognise it, so the check will report as
            unavailable rather than gating anything.
          </.callout>
        </div>

        <div class="chiprow" style="margin-top:var(--s-3)">
          <span
            :for={f <- @form_types}
            class={["badge", (not_a_reference?(f) && "attention") || "neutral"]}
            style="gap:6px"
          >
            <.icon :if={not_a_reference?(f)} name="hero-eye-slash" class="size-[12px]" />
            <span class="mono" style="font-size:12px">{f}</span>
            <button
              type="button"
              phx-click={JS.push("remove_form", value: %{form: f})}
              aria-label={"Remove #{f}"}
              class="inline-flex p-0 bg-transparent border-0 cursor-pointer text-inherit"
            >
              <.icon name="hero-x-mark" class="size-[12px]" />
            </button>
          </span>
        </div>
      </div>

      <.callout
        :if={@unreferenced_selected != []}
        tone="attention"
        icon="hero-shield-exclamation"
        title={"#{length(@unreferenced_selected)} #{ngettext("value is", "values are", length(@unreferenced_selected))} not a compliance reference"}
      >
        <b>{Enum.join(@unreferenced_selected, ", ")}</b>
        {ngettext("does", "do", length(@unreferenced_selected))} not look like an intakeform reference. Intake will not recognise {ngettext(
          "it",
          "them",
          length(@unreferenced_selected)
        )}, so the compliance check will
        report as unavailable rather than passing or failing. Replace with the <code>cref_</code>
        value from intakeform.
      </.callout>

      <div class="flex gap-2" style="margin-top:var(--s-4)">
        <.button variant="primary" type="submit" form="diagnosis-form">Save diagnosis</.button>
        <.button variant="ghost" navigate={~p"/diagnoses"}>Cancel</.button>
      </div>
    </div>
    """
  end
end
