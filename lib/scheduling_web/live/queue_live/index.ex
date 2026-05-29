defmodule SchedulingWeb.QueueLive.Index do
  use SchedulingWeb, :live_view

  alias Scheduling.Matching.Result
  alias Scheduling.Offices
  alias Scheduling.Queue

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Waiting room")
     |> assign_offices()
     |> stream(:waiting, Queue.list_waiting_entries())}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    entry = Queue.get_entry!(id)

    case Queue.accept(entry) do
      {:ok, assigned, %Result{} = result} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Accepted #{patient_name(assigned)} → #{assigned.assigned_office.name}. " <>
             "#{result.rationale}#{eligibility_detail(result)}"
         )
         |> stream_delete(:waiting, entry)
         |> assign_offices()}

      {:no_eligible_office, %Result{} = result} ->
        {:noreply, put_flash(socket, :error, result.rationale)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not accept this patient — please refresh and retry.")}
    end
  end

  defp assign_offices(socket) do
    loads = Queue.current_loads()

    offices =
      Enum.map(Offices.list_offices(), fn office ->
        load = Map.get(loads, office.id, 0)

        %{
          id: office.id,
          name: office.name,
          intake_capacity: office.intake_capacity,
          load: load,
          free: max(office.intake_capacity - load, 0)
        }
      end)

    assign(socket, :offices, offices)
  end

  defp patient_name(entry) do
    case entry.patient do
      %{name: name} when is_binary(name) -> name
      _ -> "patient ##{entry.patient_id}"
    end
  end

  defp eligibility_detail(%Result{eligible: []}), do: ""

  defp eligibility_detail(%Result{eligible: candidates}) do
    detail =
      candidates
      |> Enum.map(fn c ->
        "#{c.office.name} (#{c.free_capacity} free, #{c.surplus} surplus)"
      end)
      |> Enum.join("; ")

    " Eligible: #{detail}."
  end

  defp required_names(entry) do
    case entry.required_capabilities do
      caps when is_list(caps) and caps != [] ->
        caps |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")

      _ ->
        "—"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Waiting room
        <:subtitle>Accept a waiting patient to route them to the best-fit office.</:subtitle>
        <:actions>
          <.link navigate={~p"/decisions"} class="text-sm font-semibold">
            Routing decisions
          </.link>
        </:actions>
      </.header>

      <section class="mb-8">
        <h2 class="text-sm font-semibold mb-2">Office capacity</h2>
        <.table id="office-capacity" rows={@offices}>
          <:col :let={office} label="Office">{office.name}</:col>
          <:col :let={office} label="In service">{office.load}</:col>
          <:col :let={office} label="Capacity">{office.intake_capacity}</:col>
          <:col :let={office} label="Free">{office.free}</:col>
        </.table>
      </section>

      <section>
        <h2 class="text-sm font-semibold mb-2">Waiting patients</h2>
        <.table id="waiting" rows={@streams.waiting}>
          <:col :let={{_id, entry}} label="Patient">{patient_name(entry)}</:col>
          <:col :let={{_id, entry}} label="Required capabilities">{required_names(entry)}</:col>
          <:col :let={{_id, entry}} label="Priority">{entry.priority}</:col>
          <:action :let={{_id, entry}}>
            <.button phx-click={JS.push("accept", value: %{id: entry.id})}>Accept</.button>
          </:action>
        </.table>
      </section>
    </Layouts.app>
    """
  end
end
