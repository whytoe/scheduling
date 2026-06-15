defmodule SchedulingWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: SchedulingWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
  attr :class, :any, default: nil
  attr :variant, :string, default: "ghost", values: ~w(primary ghost subtle danger clinical)
  attr :size, :string, default: nil, doc: ~s(set to "sm" for the compact variant)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "ghost" => "btn-ghost",
      "subtle" => "btn-subtle",
      "danger" => "btn-danger",
      "clinical" => "btn-primary btn-clinical"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns.variant), assigns.size == "sm" && "btn-sm"]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # ===========================================================================
  # Redesign component library — the standardized patterns the screens compose.
  # Status is NEVER color-alone: every badge/callout carries color + icon + text.
  # ===========================================================================

  # Lifecycle + outcome status vocabulary (single source for color + icon + text).
  @status_meta %{
    "waiting" => {"waiting", "hero-clock", "Waiting"},
    "assigned" => {"assigned", "hero-arrow-right-circle", "Assigned"},
    "in_service" => {"active", "hero-bolt", "In service"},
    "completed" => {"success", "hero-check-circle", "Completed"},
    "no_eligible" => {"attention", "hero-exclamation-triangle", "No eligible office"},
    "compliance_failed" => {"error", "hero-shield-exclamation", "Compliance failed"},
    "compliance_unavailable" => {"neutral", "hero-signal-slash", "Compliance unavailable"},
    "intake_unreachable" => {"neutral", "hero-signal-slash", "Intake unreachable"},
    "sensitive" => {"attention", "hero-eye-slash", "Sensitive form"}
  }

  @doc """
  PATTERN 1 — Status badge. Always renders color + icon + text (color-blind safe).

  `status` is one of the lifecycle/outcome keys (`waiting`, `assigned`,
  `in_service`, `completed`, `no_eligible`, `compliance_failed`,
  `compliance_unavailable`, `intake_unreachable`, `sensitive`). Pass `label` to
  override the default text (e.g. `→ Room 3`).
  """
  attr :status, :string, required: true
  attr :label, :string, default: nil
  attr :size, :string, default: nil, doc: ~s(set to "lg" for the larger badge)

  def status_badge(assigns) do
    {cls, icon, label} = Map.get(@status_meta, to_string(assigns.status), @status_meta["waiting"])
    assigns = assign(assigns, cls: cls, icon: icon, default_label: label)

    ~H"""
    <span class={["badge", @cls, @size == "lg" && "badge--lg"]}>
      <.icon name={@icon} class={if(@size == "lg", do: "size-[15px]", else: "size-[13px]")} />
      {@label || @default_label}
    </span>
    """
  end

  @doc """
  Capability chip — a plain capability tag (not a status). `miss` strikes it
  through in error styling (a required capability the office can't provide);
  `sensitive` renders amber with an eye-slash icon.
  """
  attr :miss, :boolean, default: false
  attr :sensitive, :boolean, default: false
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class={["chip", @miss && "chip--miss", @sensitive && "chip--sensitive"]}>
      <.icon :if={@sensitive} name="hero-eye-slash" class="size-[12px]" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Capability chip row. `caps` is a list of names; any in `missing` are struck
  through. Renders an em-dash when empty.
  """
  attr :caps, :list, required: true
  attr :missing, :list, default: []

  def cap_row(assigns) do
    ~H"""
    <span :if={@caps == []} class="t-small">—</span>
    <span :if={@caps != []} class="chiprow">
      <.chip :for={cap <- @caps} miss={cap in @missing}>{cap}</.chip>
    </span>
    """
  end

  # Actor attribution vocabulary.
  @actor_meta %{
    "front_desk" => {"actor--frontdesk", "hero-user", "Front desk"},
    "clinician" => {"actor--clinician", "hero-hand-raised", "Clinician"},
    "queueing" => {"actor--queueing", "hero-user-group", "Queueing service"},
    "system" => {"actor--system", "hero-cpu-chip", "System"}
  }

  @doc "Actor attribution pill — who took an action (front desk / clinician / queueing / system)."
  attr :actor, :string, required: true

  def actor(assigns) do
    {cls, icon, label} = Map.get(@actor_meta, to_string(assigns.actor), @actor_meta["system"])
    assigns = assign(assigns, cls: cls, icon: icon, label: label)

    ~H"""
    <span class={["actor", @cls]}>
      <.icon name={@icon} class="size-[13px]" />{@label}
    </span>
    """
  end

  @doc """
  Priority tag for patient cards. A number, never just a hue — readable and
  color-blind safe. 3+ is urgent (red), 2 is high (amber), else neutral.
  """
  attr :priority, :integer, required: true

  def priority_tag(assigns) do
    ~H"""
    <div
      class={[
        "pcard__pri",
        @priority >= 3 && "pcard__pri--urgent",
        @priority == 2 && "pcard__pri--high"
      ]}
      title={"Priority #{@priority}"}
      aria-label={"Priority #{@priority}"}
    >
      {@priority}
    </div>
    """
  end

  @doc """
  PATTERN 3 — Office card with a segmented load meter. Slots are countable at a
  glance: used (in service) / incoming (hatched) / free. Turns red at 0 free.
  """
  attr :name, :string, required: true
  attr :capacity, :integer, required: true
  attr :load, :integer, required: true
  attr :incoming, :integer, default: 0
  attr :caps, :list, default: []
  attr :compact, :boolean, default: false

  def office_card(assigns) do
    free = max(assigns.capacity - assigns.load, 0)
    assigns = assign(assigns, :free, free)

    ~H"""
    <div class="ocard">
      <div class="ocard__top">
        <div>
          <div class="ocard__name">{@name}</div>
          <div :if={not @compact and @caps != []} class="chiprow" style="margin-top:6px">
            <.chip :for={cap <- @caps}>{cap}</.chip>
          </div>
        </div>
        <div class="ocard__cap">
          <div class="ocard__capnum tnum" style={@free == 0 && "color:var(--st-error-fg)"}>{@free}</div>
          <div class="ocard__caplbl">{if @free == 1, do: "slot free", else: "slots free"}</div>
        </div>
      </div>
      <div
        class="loadmeter"
        role="img"
        aria-label={"#{@load} in service, #{@incoming} incoming, #{@free} free of #{@capacity}"}
      >
        <span
          :for={i <- 0..(@capacity - 1)//1}
          class={[
            "loadmeter__slot",
            i < @load && (@load >= @capacity && "loadmeter__slot--full" || "loadmeter__slot--used"),
            i >= @load and i < @load + @incoming && "loadmeter__slot--incoming"
          ]}
        />
      </div>
      <div class="ocard__legend">
        <span class="ocard__legdot">
          <i style="background:var(--st-active-fg)"></i>In service <b class="tnum">{@load}</b>
        </span>
        <span :if={@incoming > 0} class="ocard__legdot">
          <i style="background:var(--st-assigned-fg);opacity:.6"></i>Incoming <b class="tnum">{@incoming}</b>
        </span>
        <span class="ocard__legdot">
          <i style="background:var(--color-base-300)"></i>Free <b class="tnum">{@free}</b>
        </span>
      </div>
    </div>
    """
  end

  @doc """
  PATTERN 7 — Error / warning callout. `tone` is `attention`, `error`, `info`,
  or `neutral`; `dashed` marks degraded/unreachable conditions. Carries an
  icon + title + body so meaning never rests on color alone.
  """
  attr :tone, :string, default: "info", values: ~w(attention error info neutral)
  attr :icon, :string, default: nil
  attr :title, :string, default: nil
  attr :dashed, :boolean, default: false
  slot :inner_block, required: true

  def callout(assigns) do
    default_icon = %{
      "attention" => "hero-exclamation-triangle",
      "error" => "hero-x-circle",
      "info" => "hero-information-circle",
      "neutral" => "hero-signal-slash"
    }

    assigns = assign_new(assigns, :resolved_icon, fn -> assigns.icon || default_icon[assigns.tone] end)

    ~H"""
    <div class={["callout", @tone, @dashed && "callout--dashed"]} role={if @tone == "error", do: "alert", else: "status"}>
      <.icon name={@resolved_icon} class="size-5 shrink-0" />
      <div class="callout__main">
        <div :if={@title} class="callout__title">{@title}</div>
        <div class="callout__body">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  @doc """
  PATTERN 6 — Empty state. Icon + reassuring "system is working" body, so an
  empty zone reads as calm rather than broken.
  """
  attr :icon, :string, default: "hero-check-circle"
  attr :title, :string, required: true
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="empty">
      <div class="empty__icon"><.icon name={@icon} class="size-6" /></div>
      <div class="empty__title">{@title}</div>
      <div :if={@inner_block != []} class="empty__body">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Design-decision annotation note (used to explain a layout choice in context)."
  slot :inner_block, required: true

  def note(assigns) do
    ~H"""
    <div class="note">
      <.icon name="hero-sparkles" class="size-[14px] shrink-0" />
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Zone header — icon + title + count pill. Optional `:right` slot for controls."
  attr :id, :string, default: nil
  attr :count_id, :string, default: nil
  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  slot :right

  def zone_head(assigns) do
    ~H"""
    <div class="zone__head">
      <div class="panel-title">
        <.icon :if={@icon} name={@icon} class="size-[18px] text-base-content/60" />
        <h2 id={@id} class="t-h2">{@title}</h2>
        <span :if={@count != nil} id={@count_id} class="zone__count tnum">{@count}</span>
      </div>
      {render_slot(@right)}
    </div>
    """
  end

  @doc "Page header — large title, optional live dot, subtitle, and actions."
  attr :title, :string, required: true
  attr :live, :boolean, default: false
  slot :subtitle
  slot :actions

  def page_head(assigns) do
    ~H"""
    <div class="pagehead">
      <div style="flex:1;min-width:0">
        <div class="flex items-center gap-[10px]">
          <h1 class="t-display">{@title}</h1>
          <span
            :if={@live}
            class="inline-flex items-center gap-[6px] text-[13px] font-semibold"
            style="color:var(--st-success-fg)"
          >
            <span class="livedot"></span> {gettext("Live")}
          </span>
        </div>
        <p :if={@subtitle != []} class="pagehead__sub">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex gap-2 flex-none">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  PATTERN 8 — Confirmation dialog. The one pronounced-elevation surface, for
  destructive / clinically-consequential actions only. Focus moves to Cancel,
  Esc and backdrop cancel, focus is trapped, and returns to the trigger on close
  (via the `ConfirmDialog` JS hook). The body must name the exact consequence.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :tone, :string, default: "error", values: ~w(error attention)
  attr :icon, :string, default: "hero-trash"
  attr :title, :string, required: true
  attr :confirm_label, :string, default: "Confirm"
  attr :on_confirm, :any, required: true, doc: "JS command or event for the confirm button"
  attr :on_cancel, :any, default: nil, doc: "JS command run on cancel/dismiss"
  slot :inner_block, required: true

  def confirm_dialog(assigns) do
    assigns = assign_new(assigns, :on_cancel, fn -> nil end)

    ~H"""
    <div
      :if={@show}
      id={@id}
      class="scrim"
      phx-hook="ConfirmDialog"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div
        class="modal"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-body"}
        phx-click-away={@on_cancel}
      >
        <div class="modal__head">
          <div class={["modal__icon", @tone]}><.icon name={@icon} class="size-[22px]" /></div>
          <div>
            <div id={"#{@id}-title"} class="modal__title">{@title}</div>
            <div id={"#{@id}-body"} class="modal__body" style="margin-top:4px">
              {render_slot(@inner_block)}
            </div>
          </div>
        </div>
        <div class="modal__actions">
          <button type="button" class="btn btn-ghost" data-confirm-cancel phx-click={@on_cancel}>
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            class={["btn", @tone == "error" && "btn-danger" || "btn-primary"]}
            phx-click={@on_confirm}
          >
            {@confirm_label}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc "PATTERN 9 — a single skeleton bar (reduced-motion falls back to a static tint)."
  attr :class, :any, default: nil
  attr :rest, :global

  def skel(assigns) do
    ~H"""
    <span class={["skel block", @class]} {@rest} />
    """
  end

  @doc "Skeleton placeholder list for first paint / reconnect on card lists."
  attr :rows, :integer, default: 4

  def skeleton_list(assigns) do
    ~H"""
    <div role="status" aria-live="polite">
      <span class="sr-only">{gettext("Loading…")}</span>
      <div :for={_ <- 1..@rows//1} class="skel-card" aria-hidden="true">
        <.skel class="skel--lg" style="width:34px;height:34px;border-radius:8px;flex:none" />
        <div style="flex:1">
          <.skel class="skel--text" style="width:40%" />
          <.skel class="skel--text" style="width:62%;margin-top:8px" />
        </div>
        <.skel style="width:70px;height:22px;border-radius:6px;flex:none" />
      </div>
    </div>
    """
  end

  @doc "Skeleton placeholder table for first paint on CRUD/visit lists."
  attr :rows, :integer, default: 5
  attr :cols, :integer, default: 4

  def skeleton_table(assigns) do
    ~H"""
    <div class="card overflow-hidden" style="padding:0" role="status">
      <span class="sr-only">{gettext("Loading…")}</span>
      <div
        :for={_ <- 1..@rows//1}
        aria-hidden="true"
        class="grid gap-[var(--s-4)]"
        style={"grid-template-columns:repeat(#{@cols},1fr);padding:var(--s-3) var(--s-4);border-bottom:1px solid var(--color-base-300)"}
      >
        <.skel :for={j <- 1..@cols//1} class="skel--text" style={"width:#{if j == 1, do: 60, else: 45}%"} />
      </div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(SchedulingWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SchedulingWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
