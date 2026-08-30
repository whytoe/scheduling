defmodule SchedulingWeb.AvailabilityLive.Index do
  @moduledoc """
  Administration for availability rules — the recurring weekly patterns slot
  generation expands (`docs/booking.md`).

  Follows the catalog CRUD shape: the "form above table" panel that reads blank
  for **new** and pre-filled for **edit**, with the destructive action routed
  through a confirmation dialog that names the consequence.

  Two things this screen has to communicate that the other catalog screens do
  not, because getting either wrong fails silently:

    * **Times are the office's local wall time.** The office's timezone is shown
      beside every group and repeated on the form, because the natural
      assumption — that 09:00 means the operator's own morning — is wrong for
      any office in another zone.
    * **Retiring is the workflow; editing is not.** A schedule change bounds the
      old rule and writes a new one. Editing in place rewrites what the calendar
      meant last month, and the slots it already produced are not revised.

  Retired rules stay listed rather than being hidden. A retired rule is the
  explanation for slots that already exist, so dropping it from the screen
  removes the only thing that makes them make sense.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Booking
  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Offices

  @day_names %{
    1 => "Monday",
    2 => "Tuesday",
    3 => "Wednesday",
    4 => "Thursday",
    5 => "Friday",
    6 => "Saturday",
    7 => "Sunday"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:offices, Offices.list_offices())
     |> assign(:confirm, nil)
     |> load_rules()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Availability")
    |> assign(:rule, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    rule = %AvailabilityRule{active: true}

    socket
    |> assign(:page_title, "New availability rule")
    |> assign(:rule, rule)
    |> assign_form(Booking.change_availability_rule(rule))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = Booking.get_availability_rule!(id)

    socket
    |> assign(:page_title, "Edit rule — #{rule.office.name}, #{day_name(rule.day_of_week)}")
    |> assign(:rule, rule)
    |> assign_form(Booking.change_availability_rule(rule))
  end

  @impl true
  def handle_event("validate", %{"availability_rule" => params}, socket) do
    changeset = Booking.change_availability_rule(socket.assigns.rule, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"availability_rule" => params}, socket) do
    save_rule(socket, socket.assigns.live_action, params)
  end

  def handle_event("confirm_retire", %{"id" => id}, socket) do
    rule = Booking.get_availability_rule!(id)
    {:noreply, assign(socket, :confirm, confirm_payload(rule))}
  end

  def handle_event("cancel_retire", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("retire", %{"id" => id}, socket) do
    rule = Booking.get_availability_rule!(id)

    case Booking.retire_availability_rule(rule, retire_on(rule)) do
      {:ok, retired} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(
           :info,
           "Retired from #{Date.to_iso8601(retired.effective_until)}. " <>
             "Slots already generated are unchanged."
         )
         |> load_rules()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not retire that rule.")}
    end
  end

  defp save_rule(socket, :new, params) do
    case Booking.create_availability_rule(params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rule created. Slots generate on the next horizon run.")
         |> load_rules()
         |> push_patch(to: ~p"/availability")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_rule(socket, :edit, params) do
    case Booking.update_availability_rule(socket.assigns.rule, params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rule updated. Slots already generated are unchanged.")
         |> load_rules()
         |> push_patch(to: ~p"/availability")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :availability_rule))
  end

  # Grouped by office so a reader sees one room's week together, which is how
  # someone actually thinks about a schedule.
  defp load_rules(socket) do
    grouped =
      Booking.list_availability_rules()
      |> Enum.group_by(& &1.office)
      |> Enum.sort_by(fn {office, _rules} -> office.name end)

    assign(socket, :grouped_rules, grouped)
  end

  defp confirm_payload(rule) do
    %{
      id: rule.id,
      office: rule.office.name,
      day: day_name(rule.day_of_week),
      window: window_label(rule),
      on: retire_on(rule)
    }
  end

  # Retiring bounds the rule with `effective_until`, and the changeset refuses
  # an `effective_until` before the `effective_from` — so a rule scheduled to
  # start next month cannot be retired "today". Bound it at its own start date
  # instead: it is deactivated either way (`applies_on?/2` short-circuits on
  # `active`), and the dates stay coherent rather than the write silently
  # failing validation.
  defp retire_on(%AvailabilityRule{effective_from: from}) do
    today = Date.utc_today()
    if Date.compare(today, from) == :lt, do: from, else: today
  end

  defp day_name(day), do: Map.get(@day_names, day, "—")

  defp window_label(rule), do: "#{format_time(rule.starts_at)}–#{format_time(rule.ends_at)}"

  defp format_time(nil), do: "—"
  defp format_time(%Time{} = time), do: time |> Time.to_string() |> String.slice(0, 5)

  defp effective_label(%AvailabilityRule{effective_from: from, effective_until: nil}),
    do: "from #{Date.to_iso8601(from)}"

  defp effective_label(%AvailabilityRule{effective_from: from, effective_until: until}),
    do: "#{Date.to_iso8601(from)} → #{Date.to_iso8601(until)}"

  # A retired rule still explains slots that exist, so it stays listed — but it
  # must not read as live capacity.
  defp retired?(%AvailabilityRule{active: active}), do: not active

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:availability}>
      <.page_head title="Availability">
        <:subtitle>
          When each office is bookable. Slot generation expands these into the calendar.
        </:subtitle>
        <:actions>
          <.button variant="primary" navigate={~p"/availability/new"}>
            <.icon name="hero-plus" class="size-4" />New rule
          </.button>
        </:actions>
      </.page_head>

      <.callout tone="info" icon="hero-clock" title="Times are each office's local time">
        A window of 09:00–17:00 means nine in the morning <em>where that room is</em>, not in your
        own timezone. Each office's zone is shown beside its name below.
      </.callout>

      <.availability_form
        :if={@live_action in [:new, :edit]}
        form={@form}
        page_title={@page_title}
        offices={@offices}
        editing={@live_action == :edit}
      />

      <.empty_state
        :if={@grouped_rules == []}
        icon="hero-calendar-days"
        title="No availability yet"
      >
        No office is bookable until it has at least one rule. Add one to start generating slots.
      </.empty_state>

      <div :for={{office, rules} <- @grouped_rules} class="card" style="margin-top:var(--s-5)">
        <.zone_head title={office.name} icon="hero-building-office" count={length(rules)}>
          <:right>
            <span class="chip">
              <.icon name="hero-globe-alt" class="size-[12px]" />{office.timezone}
            </span>
          </:right>
        </.zone_head>

        <table class="table">
          <thead>
            <tr>
              <th style="width:130px">Day</th>
              <th style="width:150px">Window (local)</th>
              <th style="width:110px">Slot length</th>
              <th style="width:90px">Slots/day</th>
              <th>In effect</th>
              <th style="width:1px"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={rule <- rules}
              id={"rule-#{rule.id}"}
              style={retired?(rule) && "opacity:0.55"}
            >
              <td class="font-semibold">{day_name(rule.day_of_week)}</td>
              <td class="tnum">{window_label(rule)}</td>
              <td class="tnum">{rule.slot_minutes} min</td>
              <td class="tnum">{AvailabilityRule.slot_count(rule)}</td>
              <td>
                <span class="t-small">{effective_label(rule)}</span>
                <span :if={retired?(rule)} class="chip" style="margin-left:var(--s-2)">
                  <.icon name="hero-archive-box" class="size-[12px]" />Retired
                </span>
              </td>
              <td>
                <div class="table__actions">
                  <.link
                    navigate={~p"/availability/#{rule}/edit"}
                    class="btn btn-ghost btn-sm"
                    aria-label={"Edit #{office.name} #{day_name(rule.day_of_week)} rule"}
                  >
                    <.icon name="hero-pencil-square" class="size-[15px]" />
                  </.link>
                  <button
                    :if={not retired?(rule)}
                    type="button"
                    class="btn btn-danger btn-sm"
                    aria-label={"Retire #{office.name} #{day_name(rule.day_of_week)} rule"}
                    phx-click={JS.push("confirm_retire", value: %{id: rule.id})}
                  >
                    <.icon name="hero-archive-box-arrow-down" class="size-[15px]" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.confirm_dialog
        id="retire-rule"
        show={@confirm != nil}
        tone="attention"
        icon="hero-archive-box-arrow-down"
        title="Retire this rule?"
        confirm_label="Retire rule"
        on_confirm={@confirm && JS.push("retire", value: %{id: @confirm.id})}
        on_cancel={JS.push("cancel_retire")}
      >
        <span :if={@confirm}>
          <b>{@confirm.office}</b>
          will stop generating new {@confirm.day} slots for {@confirm.window} from
          <b>{Date.to_iso8601(@confirm.on)}</b>
          . Slots already generated stay, including any that are booked — nothing is cancelled.
          The rule remains listed so those slots stay explicable.
        </span>
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :page_title, :string, required: true
  attr :offices, :list, required: true
  attr :editing, :boolean, default: false

  defp availability_form(assigns) do
    ~H"""
    <div class="editform">
      <div class="editform__title">
        <.icon name="hero-pencil-square" class="size-[18px]" />{@page_title}
      </div>

      <.callout
        :if={@editing}
        tone="attention"
        icon="hero-exclamation-triangle"
        title="Editing rewrites the past"
      >
        For a <em>schedule change</em>, retire this rule and write a new one instead. Editing in
        place changes what the calendar meant on dates already covered, and the slots it produced
        are not revised — nothing prunes them. Use this to correct a mistake.
      </.callout>

      <.form for={@form} id="availability-rule-form" phx-change="validate" phx-submit="save">
        <div class="cols cols--2" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="availability_rule_office_id">Office</label>
            <select id="availability_rule_office_id" name="availability_rule[office_id]" class="input">
              <option value="">Choose an office…</option>
              <option
                :for={office <- @offices}
                value={office.id}
                selected={to_string(@form[:office_id].value) == to_string(office.id)}
              >
                {office.name} ({office.timezone})
              </option>
            </select>
            <div class="field__hint">The window below is in this office's local time.</div>
            <.field_errors field={@form[:office_id]} />
          </div>

          <div class="field">
            <label class="field__label" for="availability_rule_day_of_week">Day</label>
            <select
              id="availability_rule_day_of_week"
              name="availability_rule[day_of_week]"
              class="input"
            >
              <option value="">Choose a day…</option>
              <option
                :for={day <- AvailabilityRule.days()}
                value={day}
                selected={to_string(@form[:day_of_week].value) == to_string(day)}
              >
                {day_name(day)}
              </option>
            </select>
            <.field_errors field={@form[:day_of_week]} />
          </div>
        </div>

        <div class="cols cols--2" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="availability_rule_starts_at">Opens (local)</label>
            <input
              type="time"
              id="availability_rule_starts_at"
              name="availability_rule[starts_at]"
              value={Phoenix.HTML.Form.normalize_value("time", @form[:starts_at].value)}
              class="input tnum"
            />
            <.field_errors field={@form[:starts_at]} />
          </div>

          <div class="field">
            <label class="field__label" for="availability_rule_ends_at">Closes (local)</label>
            <input
              type="time"
              id="availability_rule_ends_at"
              name="availability_rule[ends_at]"
              value={Phoenix.HTML.Form.normalize_value("time", @form[:ends_at].value)}
              class="input tnum"
            />
            <.field_errors field={@form[:ends_at]} />
          </div>
        </div>

        <div class="cols cols--2" style="gap:var(--s-4)">
          <div class="field">
            <label class="field__label" for="availability_rule_slot_minutes">Slot length</label>
            <input
              type="number"
              min="1"
              max="480"
              id="availability_rule_slot_minutes"
              name="availability_rule[slot_minutes]"
              value={Phoenix.HTML.Form.normalize_value("number", @form[:slot_minutes].value)}
              class="input tnum"
              placeholder="20"
            />
            <div class="field__hint">
              Minutes. A trailing part-slot is dropped, not rounded up.
            </div>
            <.field_errors field={@form[:slot_minutes]} />
          </div>

          <div class="field">
            <label class="field__label" for="availability_rule_effective_from">
              In effect from
            </label>
            <input
              type="date"
              id="availability_rule_effective_from"
              name="availability_rule[effective_from]"
              value={Phoenix.HTML.Form.normalize_value("date", @form[:effective_from].value)}
              class="input tnum"
            />
            <.field_errors field={@form[:effective_from]} />
          </div>
        </div>

        <div class="field">
          <label class="field__label" for="availability_rule_effective_until">
            In effect until — optional
          </label>
          <input
            type="date"
            id="availability_rule_effective_until"
            name="availability_rule[effective_until]"
            value={Phoenix.HTML.Form.normalize_value("date", @form[:effective_until].value)}
            class="input tnum"
          />
          <div class="field__hint">Leave blank for an open-ended rule.</div>
          <.field_errors field={@form[:effective_until]} />
        </div>

        <div class="flex gap-2" style="margin-top:var(--s-4)">
          <.button variant="primary" type="submit">Save rule</.button>
          <.button variant="ghost" navigate={~p"/availability"}>Cancel</.button>
        </div>
      </.form>
    </div>
    """
  end
end
