defmodule SchedulingWeb.VisitLive.Index do
  @moduledoc """
  The visit list + detail. A table of every visit (id, patient, diagnosis,
  opened, status); a row expands to the shared lifecycle timeline. Shows a
  skeleton table on first paint (and a Reload control), reusing the audit-row +
  timeline patterns so this new surface feels native to the rest of the system.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Audit
  alias Scheduling.Repo
  alias Scheduling.Visits
  alias SchedulingWeb.EventTimeline

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Visits")
      |> assign(:open_id, nil)
      |> assign(:open_events, [])

    # Skeleton on the static first paint; real data once the socket connects.
    if connected?(socket) do
      {:ok, assign(socket, loading: false, visits: load_visits())}
    else
      {:ok, assign(socket, loading: true, visits: [])}
    end
  end

  @impl true
  def handle_event("reload", _params, socket) do
    {:noreply, assign(socket, visits: load_visits(), open_id: nil, open_events: [])}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    id = if is_binary(id), do: String.to_integer(id), else: id

    if socket.assigns.open_id == id do
      {:noreply, assign(socket, open_id: nil, open_events: [])}
    else
      events = Audit.list_events(visit_id: id) |> EventTimeline.view_events()
      {:noreply, assign(socket, open_id: id, open_events: events)}
    end
  end

  defp load_visits do
    Visits.list_visits()
    |> Repo.preload(queue_entries: :diagnosis)
    |> Enum.map(fn v ->
      %{
        id: v.id,
        label: "v-#{v.id}",
        patient: patient_name(v),
        diagnosis: diagnosis_name(v),
        opened: format_at(v.started_at),
        status: status_key(v.status)
      }
    end)
  end

  defp patient_name(visit) do
    case visit.patient do
      %{name: name} when is_binary(name) -> name
      _ -> "patient ##{visit.patient_id}"
    end
  end

  # A visit can hold several queue entries; surface the first diagnosis we find.
  defp diagnosis_name(visit) do
    visit.queue_entries
    |> Enum.map(& &1.diagnosis)
    |> Enum.find_value(fn
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end) || "—"
  end

  defp status_key(:ended), do: "completed"
  defp status_key(_), do: "in_service"

  defp format_at(nil), do: "—"
  defp format_at(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:visits}>
      <.page_head title="Visits">
        <:subtitle>
          Every visit and its lifecycle. Open one to see the timeline of queue entries and events.
        </:subtitle>
        <:actions>
          <.button variant="ghost" phx-click="reload">
            <.icon name="hero-arrow-path" class="size-4" />Reload
          </.button>
        </:actions>
      </.page_head>

      <.skeleton_table :if={@loading} rows={4} cols={5} />

      <div :if={not @loading and @visits == []} class="card">
        <.empty_state icon="hero-rectangle-stack" title="No visits yet">
          Visits appear here as patients are seen. The list updates when you reload.
        </.empty_state>
      </div>

      <div :if={not @loading and @visits != []} class="card overflow-hidden" style="padding:0">
        <table class="table">
          <thead>
            <tr>
              <th style="width:120px">Visit</th>
              <th>Patient</th>
              <th>Diagnosis</th>
              <th style="width:150px">Opened</th>
              <th style="width:150px">Status</th>
              <th style="width:1px"><span class="sr-only">Timeline</span></th>
            </tr>
          </thead>
          <tbody>
            <%= for v <- @visits do %>
              <tr style="cursor:pointer" phx-click={JS.push("toggle", value: %{id: v.id})}>
                <td class="mono t-small">{v.label}</td>
                <td class="font-semibold">{v.patient}</td>
                <td>{v.diagnosis}</td>
                <td class="mono t-small">{v.opened}</td>
                <td><.status_badge status={v.status} /></td>
                <td>
                  <span class="btn btn-ghost btn-sm" aria-hidden="true">
                    <.icon
                      name="hero-chevron-down"
                      class={["size-[15px] transition-transform", @open_id == v.id && "rotate-180"]}
                    />
                  </span>
                </td>
              </tr>
              <tr :if={@open_id == v.id}>
                <td colspan="6" style="background:var(--color-base-150);padding:var(--s-4) var(--s-6)">
                  <.timeline :if={@open_events != []} events={@open_events} />
                  <p :if={@open_events == []} class="t-small">No events recorded for this visit yet.</p>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
