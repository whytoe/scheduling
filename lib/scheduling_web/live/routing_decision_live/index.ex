defmodule SchedulingWeb.RoutingDecisionLive.Index do
  @moduledoc """
  The routing-decisions audit log: every matcher run, reverse-chronological.
  A filter bar narrows by patient and by outcome; each row expands to reveal the
  required capabilities, eligible/chosen offices, who accepted, and the verbatim
  rationale (the audit artifact, shown in mono — not a paraphrase).
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Audit

  @outcomes [
    {"all", "All"},
    {"assigned", "Assigned"},
    {"no_eligible", "No eligible"},
    {"compliance_failed", "Compliance failed"},
    {"compliance_unavailable", "Compliance unavailable"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Routing decisions")
     |> assign(:outcomes, @outcomes)
     |> assign(:outcome, "all")
     |> assign(:query, "")
     |> assign(:open_id, nil)
     |> assign(:decisions, load_decisions())
     |> apply_filters()}
  end

  @impl true
  def handle_event("filter", %{"outcome" => outcome}, socket) do
    {:noreply, socket |> assign(:outcome, outcome) |> apply_filters()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:query, q) |> apply_filters()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    id = if is_binary(id), do: String.to_integer(id), else: id
    {:noreply, assign(socket, :open_id, if(socket.assigns.open_id == id, do: nil, else: id))}
  end

  defp load_decisions do
    Enum.map(Audit.list_decisions(), &to_view/1)
  end

  defp to_view(d) do
    %{
      id: d.id,
      at: Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M:%S"),
      patient: decision_patient(d),
      required: List.wrap(d.required_capabilities) |> Enum.sort(),
      eligible: List.wrap(d.eligible_offices),
      chosen: d.chosen_office_name,
      accepted_by: d.accepted_by,
      outcome: outcome(d),
      rationale: d.rationale
    }
  end

  # The schema stores no explicit outcome; derive it from the chosen office and
  # the rationale the accept flow recorded.
  defp outcome(%{chosen_office_name: name}) when is_binary(name) and name != "", do: "assigned"

  defp outcome(%{rationale: r}) when is_binary(r) do
    cond do
      String.starts_with?(r, "Compliance check failed") -> "compliance_failed"
      String.starts_with?(r, "Compliance check unavailable") -> "compliance_unavailable"
      true -> "no_eligible"
    end
  end

  defp outcome(_), do: "no_eligible"

  defp apply_filters(socket) do
    %{outcome: outcome, query: query, decisions: decisions} = socket.assigns
    q = query |> to_string() |> String.downcase() |> String.trim()

    filtered =
      decisions
      |> Enum.filter(fn d -> outcome == "all" or d.outcome == outcome end)
      |> Enum.filter(fn d -> q == "" or String.contains?(String.downcase(d.patient), q) end)

    assign(socket, :filtered, filtered)
  end

  defp decision_patient(decision) do
    cond do
      is_binary(decision.patient_name) and decision.patient_name != "" -> decision.patient_name
      match?(%{name: name} when is_binary(name), decision.patient) -> decision.patient.name
      true -> "—"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:decisions}>
      <.page_head title="Routing decisions">
        <:subtitle>
          Every matcher run, reverse-chronological. Each row reveals the rationale and
          the eligible / chosen offices — the record clinical-quality reviews start from.
        </:subtitle>
      </.page_head>

      <%!-- FILTER BAR --%>
      <div
        class="card card__body flex flex-wrap items-center gap-[var(--s-3)]"
        style="margin-bottom:var(--s-4)"
      >
        <form phx-change="search" class="relative flex-1 min-w-[220px]">
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
            placeholder="Filter by patient…"
            aria-label="Filter by patient"
          />
        </form>
        <div role="tablist" aria-label="Outcome filter" class="flex gap-1 flex-wrap">
          <button
            :for={{id, label} <- @outcomes}
            type="button"
            role="tab"
            aria-selected={@outcome == id}
            class={["navlink", @outcome == id && "navlink--active"]}
            phx-click={JS.push("filter", value: %{outcome: id})}
          >
            {label}
          </button>
        </div>
      </div>

      <div :if={@filtered == []} class="card">
        <.empty_state icon="hero-document-magnifying-glass" title="No matching decisions">
          No routing decisions match this filter. Try a broader outcome or clear the search.
        </.empty_state>
      </div>

      <div :if={@filtered != []} class="audit">
        <div :for={d <- @filtered}>
          <button
            type="button"
            class="audit__row"
            aria-expanded={@open_id == d.id}
            phx-click={JS.push("toggle", value: %{id: d.id})}
          >
            <span class="audit__time">{d.at}</span>
            <span class="flex-1 min-w-0 font-semibold">{d.patient}</span>
            <.cap_row caps={d.required} />
            <.status_badge status={d.outcome} />
            <.icon
              name="hero-chevron-down"
              class={[
                "size-4 text-base-content/50 transition-transform",
                @open_id == d.id && "rotate-180"
              ]}
            />
          </button>

          <div :if={@open_id == d.id} class="audit__detail">
            <dl class="dl">
              <dt>Required</dt>
              <dd><.cap_row caps={d.required} /></dd>
              <dt>Eligible offices</dt>
              <dd>
                <span :if={d.eligible == []} class="t-small">none</span>
                <span :if={d.eligible != []}>{Enum.join(d.eligible, ", ")}</span>
              </dd>
              <dt>Chosen</dt>
              <dd>
                <span :if={d.chosen}>{d.chosen}</span>
                <span :if={!d.chosen} style="color:var(--st-attention-fg)">No office</span>
              </dd>
              <dt>Accepted by</dt>
              <dd>
                <.actor :if={d.accepted_by} actor={d.accepted_by} />
                <span :if={!d.accepted_by} class="t-small">—</span>
              </dd>
            </dl>
            <div class="audit__rationale">{d.rationale}</div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
