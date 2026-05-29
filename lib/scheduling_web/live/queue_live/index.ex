defmodule SchedulingWeb.QueueLive.Index do
  use SchedulingWeb, :live_view

  alias Scheduling.Matching.Result
  alias Scheduling.Offices
  alias Scheduling.Queue

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Queue.subscribe_board()

    {:ok,
     socket
     |> assign(:page_title, "Waiting room")
     |> assign(:capabilities, Offices.list_capabilities())
     |> load_board()}
  end

  @impl true
  def handle_info({:board_changed, _event}, socket) do
    {:noreply, load_board(socket)}
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
         |> load_board()}

      {:no_eligible_office, %Result{} = result} ->
        {:noreply, put_flash(socket, :error, result.rationale)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not accept this patient — please refresh and retry.")}
    end
  end

  def handle_event("complete", %{"id" => id}, socket) do
    entry = Queue.get_entry!(id)

    case Queue.complete(entry) do
      {:ok, completed} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Completed service for #{patient_name(completed)} — #{office_label(entry)} slot freed."
         )
         |> load_board()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not complete — please refresh and retry.")}
    end
  end

  def handle_event("requeue", %{"entry_id" => id} = params, socket) do
    entry = Queue.get_entry!(id)
    capabilities = selected_capabilities(socket.assigns.capabilities, params)

    case Queue.requeue(entry, capabilities) do
      {:ok, requeued} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Re-queued #{patient_name(requeued)} for additional service."
         )
         |> load_board()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not re-queue — please refresh and retry.")}
    end
  end

  defp load_board(socket) do
    waiting = Queue.list_waiting_entries()
    active = Queue.list_active_entries()

    socket
    |> assign_offices()
    |> assign(:active_count, length(active))
    |> stream(:waiting, waiting, reset: true)
    |> stream(:active, active, reset: true)
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

  defp selected_capabilities(capabilities, params) do
    ids =
      params
      |> Map.get("capability_ids", [])
      |> List.wrap()
      |> MapSet.new()

    Enum.filter(capabilities, &MapSet.member?(ids, to_string(&1.id)))
  end

  defp patient_name(entry) do
    case entry.patient do
      %{name: name} when is_binary(name) -> name
      _ -> "patient ##{entry.patient_id}"
    end
  end

  defp office_label(entry) do
    case entry.assigned_office do
      %{name: name} when is_binary(name) -> name
      _ -> "office"
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

      <section class="mb-8">
        <h2 class="text-sm font-semibold mb-2">In service ({@active_count})</h2>
        <.table id="active" rows={@streams.active}>
          <:col :let={{_id, entry}} label="Patient">{patient_name(entry)}</:col>
          <:col :let={{_id, entry}} label="Office">{office_label(entry)}</:col>
          <:col :let={{_id, entry}} label="Required capabilities">{required_names(entry)}</:col>
          <:action :let={{_id, entry}}>
            <.button
              id={"complete-#{entry.id}"}
              phx-click={JS.push("complete", value: %{id: entry.id})}
            >
              Complete
            </.button>
            <form id={"requeue-form-#{entry.id}"} phx-submit="requeue" class="flex items-center gap-2">
              <input type="hidden" name="entry_id" value={entry.id} />
              <select
                name="capability_ids[]"
                multiple
                class="select select-bordered select-sm min-w-32"
              >
                <option :for={capability <- @capabilities} value={capability.id}>
                  {capability.name}
                </option>
              </select>
              <.button type="submit">Re-queue</.button>
            </form>
          </:action>
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
