defmodule SchedulingWeb.BoardLive.Index do
  @moduledoc """
  The live shared board: the single source of truth front-desk and clinical
  staff watch. Shows the waiting-room queue (with required capabilities and time
  waiting) alongside every office's capabilities and real-time used/free intake
  capacity. It also surfaces incoming-patient handoffs — who is on their way to
  each office and what they need — which clinical staff acknowledge once the
  patient arrives. Subscribes to `Scheduling.Queue.board_topic/0` and
  `Scheduling.Handoffs.handoffs_topic/0` so acceptances, capacity changes, and
  handoffs push to every connected board without a refresh.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Queue
  alias Scheduling.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Queue.subscribe_board()
      Handoffs.subscribe_handoffs()
    end

    {:ok,
     socket
     |> assign(:page_title, "Board")
     |> load_board()}
  end

  @impl true
  def handle_info({:board_changed, _event}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:handoff_created, _handoff}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:handoff_acknowledged, _handoff}, socket) do
    {:noreply, load_board(socket)}
  end

  @impl true
  def handle_event("complete", %{"id" => id}, socket) do
    entry = Queue.get_entry!(id)

    case Queue.complete(entry) do
      {:ok, completed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Completed #{patient_name(completed)} — office capacity freed.")
         |> load_board()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not complete this patient — please refresh and retry.")}
    end
  end

  def handle_event("requeue", %{"id" => id}, socket) do
    entry = Queue.get_entry!(id)

    case Queue.requeue(entry) do
      {:ok, requeued} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Re-queued #{patient_name(requeued)} for another service — office capacity freed."
         )
         |> load_board()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not re-queue this patient — please refresh and retry.")}
    end
  end

  def handle_event("acknowledge_handoff", %{"id" => id}, socket) do
    handoff = Handoffs.get_handoff!(id)

    case Handoffs.acknowledge(handoff, acknowledged_by: "clinical") do
      {:ok, acknowledged} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Acknowledged #{handoff_patient(acknowledged)} — handoff cleared."
         )
         |> load_board()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not acknowledge this handoff — please refresh and retry."
         )}
    end
  end

  defp load_board(socket) do
    loads = Queue.current_loads()
    pending = Handoffs.list_pending()
    incoming_by_office = Enum.group_by(pending, & &1.office_id)
    now = DateTime.utc_now()

    offices =
      Enum.map(Offices.list_offices(), fn office ->
        load = Map.get(loads, office.id, 0)

        %{
          id: office.id,
          name: office.name,
          intake_capacity: office.intake_capacity,
          caps: capability_list(office.capabilities),
          load: load,
          incoming: length(Map.get(incoming_by_office, office.id, []))
        }
      end)

    incoming =
      Enum.map(pending, fn handoff ->
        %{
          id: handoff.id,
          name: handoff_patient(handoff),
          office: handoff.office_name || "office ##{handoff.office_id}",
          caps: sorted_strings(handoff.required_capabilities)
        }
      end)

    waiting =
      Queue.list_waiting_entries()
      |> Repo.preload(:diagnosis)
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          name: patient_name(entry),
          diagnosis: diagnosis_name(entry),
          caps: capability_list(entry.required_capabilities),
          priority: entry.priority,
          wait: format_wait(now, entry.inserted_at)
        }
      end)

    active =
      Enum.map(Queue.list_active_entries(), fn entry ->
        %{
          id: entry.id,
          name: patient_name(entry),
          office: office_name(entry),
          status: to_string(entry.status),
          since: format_wait(now, entry.inserted_at)
        }
      end)

    socket
    |> assign(:offices, offices)
    |> assign(:incoming, incoming)
    |> assign(:incoming_count, length(incoming))
    |> assign(:waiting, waiting)
    |> assign(:waiting_count, length(waiting))
    |> assign(:active, active)
    |> assign(:active_count, length(active))
  end

  defp capability_list(caps) when is_list(caps), do: caps |> Enum.map(& &1.name) |> Enum.sort()
  defp capability_list(_), do: []

  defp sorted_strings(caps) when is_list(caps), do: Enum.sort(caps)
  defp sorted_strings(_), do: []

  defp handoff_patient(handoff) do
    handoff.patient_name || "patient ##{handoff.patient_id}"
  end

  defp patient_name(entry) do
    case entry.patient do
      %{name: name} when is_binary(name) -> name
      _ -> "patient ##{entry.patient_id}"
    end
  end

  defp diagnosis_name(entry) do
    case entry.diagnosis do
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp office_name(entry) do
    case entry.assigned_office do
      %{name: name} when is_binary(name) -> name
      _ -> "—"
    end
  end

  defp format_wait(_now, nil), do: "—"

  defp format_wait(now, inserted_at) do
    seconds = DateTime.diff(now, inserted_at, :second) |> max(0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:board} wide>
      <.page_head title="Shared board" live>
        <:subtitle>
          One source of truth for front desk and clinical staff. Every change pushes
          live — no refresh.
        </:subtitle>
      </.page_head>

      <div class="cols cols--board">
        <%!-- WAITING --%>
        <section aria-labelledby="zone-waiting">
          <.zone_head
            id="zone-waiting"
            count_id="board-waiting-count"
            icon="hero-clock"
            title="Waiting room"
            count={@waiting_count}
          />
          <div :if={@waiting == []} class="card">
            <.empty_state icon="hero-check-circle" title="Waiting room is clear">
              No patients are waiting. The board is live and listening for new sign-ins.
            </.empty_state>
          </div>
          <div :if={@waiting != []} id="board-waiting" class="stack">
            <div :for={p <- @waiting} class="pcard">
              <.priority_tag priority={p.priority} />
              <div class="pcard__main">
                <div class="pcard__name">{p.name}</div>
                <div class="pcard__meta">
                  <span :if={p.diagnosis} class="t-small">{p.diagnosis}</span>
                  <span :if={p.diagnosis} style="color:var(--color-base-300)">·</span>
                  <.cap_row caps={p.caps} />
                </div>
              </div>
              <div class="pcard__side">
                <.status_badge status="waiting" />
                <span class="pcard__wait tnum" title="Waiting time">{p.wait}</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- INCOMING --%>
        <section aria-labelledby="zone-incoming">
          <.zone_head
            id="zone-incoming"
            count_id="board-incoming-count"
            icon="hero-arrow-right-circle"
            title="Incoming — awaiting acknowledgement"
            count={@incoming_count}
          />
          <div :if={@incoming == []} class="card">
            <.empty_state icon="hero-hand-raised" title="Nothing incoming">
              All handoffs acknowledged. New routed patients appear here for clinical staff to confirm.
            </.empty_state>
          </div>
          <div :if={@incoming != []} id="board-incoming" class="stack">
            <div :for={p <- @incoming} class="pcard" style="border-color:var(--st-assigned-line)">
              <div class="pcard__main">
                <div class="pcard__name">{p.name}</div>
                <div class="pcard__meta">
                  <.status_badge status="assigned" label={"→ #{p.office}"} />
                  <.cap_row caps={p.caps} />
                </div>
              </div>
              <.button
                variant="clinical"
                phx-click={JS.push("acknowledge_handoff", value: %{id: p.id})}
                aria-label={"Acknowledge #{p.name}"}
              >
                <.icon name="hero-hand-raised" class="size-5" />Acknowledge
              </.button>
            </div>
          </div>
        </section>

        <%!-- OFFICES + IN SERVICE --%>
        <section aria-labelledby="zone-offices">
          <.zone_head
            id="zone-offices"
            icon="hero-building-office"
            title="Office capacity"
            count={length(@offices)}
          />
          <div :if={@offices == []} class="card">
            <.empty_state icon="hero-building-office" title="No offices configured">
              Add an office to start routing patients.
            </.empty_state>
          </div>
          <div :if={@offices != []} class="grid-cards">
            <.office_card
              :for={o <- @offices}
              name={o.name}
              capacity={o.intake_capacity}
              load={o.load}
              incoming={o.incoming}
              compact
            />
          </div>

          <div style="margin-top:var(--s-6)">
            <.zone_head
              id="zone-active"
              count_id="board-active-count"
              icon="hero-bolt"
              title="In service"
              count={@active_count}
            />
            <div :if={@active == []} class="card">
              <.empty_state icon="hero-bolt" title="No one in service">
                Acknowledged patients in service will show here.
              </.empty_state>
            </div>
            <div :if={@active != []} id="board-active" class="stack">
              <div :for={p <- @active} class="pcard">
                <div class="pcard__main">
                  <div class="pcard__name">{p.name}</div>
                  <div class="pcard__meta">
                    <span class="t-small">{p.office}</span>
                    <.status_badge status={p.status} />
                  </div>
                </div>
                <div class="pcard__side">
                  <span class="pcard__wait tnum">{p.since}</span>
                  <.button
                    variant="subtle"
                    size="sm"
                    phx-click={JS.push("complete", value: %{id: p.id})}
                  >
                    Complete
                  </.button>
                  <.button
                    variant="ghost"
                    size="sm"
                    phx-click={JS.push("requeue", value: %{id: p.id})}
                  >
                    Re-queue
                  </.button>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
