defmodule SchedulingWeb.VisitEventLive.Index do
  @moduledoc """
  The lifecycle timeline: visit events grouped by visit (or, for events that
  predate a visit, by queue entry / patient). Each group expands to a vertical
  timeline — sign-in → handoff acknowledged → completed — with actor attribution
  and mono timestamps on every event. Every state change is attributable.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Audit
  alias Scheduling.Repo
  alias SchedulingWeb.EventTimeline

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Visit events")
     |> assign(:open_id, nil)
     |> assign(:groups, load_groups())}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, :open_id, if(socket.assigns.open_id == id, do: nil, else: id))}
  end

  defp load_groups do
    Audit.list_events()
    |> Repo.preload([:patient])
    |> Enum.group_by(&group_key/1)
    |> Enum.map(&build_group/1)
    |> Enum.sort_by(& &1.opened_sort, {:desc, DateTime})
  end

  defp group_key(e) do
    cond do
      e.visit_id -> {:visit, e.visit_id}
      e.queue_entry_id -> {:entry, e.queue_entry_id}
      true -> {:patient, e.patient_id}
    end
  end

  defp build_group({key, events}) do
    ordered = Enum.sort_by(events, & &1.occurred_at, DateTime)
    first = hd(ordered)
    types = Enum.map(events, & &1.type)

    %{
      id: key_id(key),
      label: key_label(key),
      patient: patient_name(first),
      status: EventTimeline.derive_status(types),
      opened: Calendar.strftime(first.occurred_at, "%Y-%m-%d %H:%M"),
      opened_sort: first.occurred_at,
      count: length(ordered),
      events: EventTimeline.view_events(ordered)
    }
  end

  defp key_id({:visit, id}), do: "visit-#{id}"
  defp key_id({:entry, id}), do: "entry-#{id}"
  defp key_id({:patient, id}), do: "patient-#{id}"

  defp key_label({:visit, id}), do: "v-#{id}"
  defp key_label({:entry, id}), do: "entry ##{id}"
  defp key_label({:patient, id}), do: "patient ##{id}"

  defp patient_name(e) do
    case e.patient do
      %{name: name} when is_binary(name) -> name
      _ -> if e.patient_id, do: "patient ##{e.patient_id}", else: "—"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:visit_events}>
      <.page_head title="Visit events">
        <:subtitle>
          The lifecycle timeline grouped by visit: sign-in → acknowledged → completion,
          with actor attribution on every event.
        </:subtitle>
      </.page_head>

      <div :if={@groups == []} class="card">
        <.empty_state icon="hero-clock" title="No visit events yet">
          Lifecycle events appear here as patients sign in, get acknowledged, and complete.
        </.empty_state>
      </div>

      <div :if={@groups != []} class="stack" style="gap:var(--s-4)">
        <div :for={g <- @groups} class="card">
          <button
            type="button"
            class="audit__row"
            style="border-bottom:none"
            aria-expanded={@open_id == g.id}
            phx-click={JS.push("toggle", value: %{id: g.id})}
          >
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="mono t-small">{g.label}</span>
                <span class="font-semibold">{g.patient}</span>
              </div>
              <div class="t-small">{g.count} events · opened {g.opened}</div>
            </div>
            <.status_badge status={g.status} />
            <.icon
              name="hero-chevron-down"
              class={[
                "size-4 text-base-content/50 transition-transform",
                @open_id == g.id && "rotate-180"
              ]}
            />
          </button>

          <div
            :if={@open_id == g.id}
            style="padding:var(--s-4) var(--s-6);border-top:1px solid var(--color-base-300)"
          >
            <.timeline events={g.events} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
