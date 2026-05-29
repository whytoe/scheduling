defmodule SchedulingWeb.BoardLive.Index do
  @moduledoc """
  The live shared board: the single source of truth front-desk and clinical
  staff watch. Shows the waiting-room queue (with required capabilities and time
  waiting) alongside every office's capabilities and real-time used/free intake
  capacity. Subscribes to `Scheduling.Queue.board_topic/0` so acceptances and
  capacity changes push to every connected board without a refresh.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Offices
  alias Scheduling.Queue

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Queue.subscribe_board()

    {:ok,
     socket
     |> assign(:page_title, "Board")
     |> load_board()}
  end

  @impl true
  def handle_info({:board_changed, _event}, socket) do
    {:noreply, load_board(socket)}
  end

  defp load_board(socket) do
    loads = Queue.current_loads()
    now = DateTime.utc_now()

    offices =
      Enum.map(Offices.list_offices(), fn office ->
        load = Map.get(loads, office.id, 0)

        %{
          id: office.id,
          name: office.name,
          intake_capacity: office.intake_capacity,
          capabilities: capability_names(office.capabilities),
          load: load,
          free: max(office.intake_capacity - load, 0)
        }
      end)

    waiting =
      Enum.map(Queue.list_waiting_entries(), fn entry ->
        %{
          id: entry.id,
          patient: patient_name(entry),
          required: capability_names(entry.required_capabilities),
          priority: entry.priority,
          waiting_for: format_wait(now, entry.inserted_at)
        }
      end)

    socket
    |> assign(:offices, offices)
    |> assign(:waiting, waiting)
    |> assign(:waiting_count, length(waiting))
  end

  defp capability_names(caps) when is_list(caps) and caps != [] do
    caps |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
  end

  defp capability_names(_), do: "—"

  defp patient_name(entry) do
    case entry.patient do
      %{name: name} when is_binary(name) -> name
      _ -> "patient ##{entry.patient_id}"
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
    <Layouts.app flash={@flash}>
      <.header>
        Shared board
        <:subtitle>
          Live view of the waiting room and office capacity. Updates in real time as
          patients are accepted.
        </:subtitle>
      </.header>

      <section class="mb-8">
        <h2 class="text-sm font-semibold mb-2">Offices</h2>
        <.table id="board-offices" rows={@offices}>
          <:col :let={office} label="Office">{office.name}</:col>
          <:col :let={office} label="Capabilities">{office.capabilities}</:col>
          <:col :let={office} label="In service">{office.load}</:col>
          <:col :let={office} label="Capacity">{office.intake_capacity}</:col>
          <:col :let={office} label="Free">{office.free}</:col>
        </.table>
      </section>

      <section>
        <h2 class="text-sm font-semibold mb-2">Waiting room ({@waiting_count})</h2>
        <.table id="board-waiting" rows={@waiting}>
          <:col :let={entry} label="Patient">{entry.patient}</:col>
          <:col :let={entry} label="Required capabilities">{entry.required}</:col>
          <:col :let={entry} label="Priority">{entry.priority}</:col>
          <:col :let={entry} label="Waiting">{entry.waiting_for}</:col>
        </.table>
      </section>
    </Layouts.app>
    """
  end
end
