defmodule SchedulingWeb.RoutingDecisionLive.Index do
  use SchedulingWeb, :live_view

  alias Scheduling.Audit

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Routing decisions")
     |> stream(:decisions, Audit.list_decisions())}
  end

  defp decision_patient(decision) do
    cond do
      is_binary(decision.patient_name) -> decision.patient_name
      match?(%{name: name} when is_binary(name), decision.patient) -> decision.patient.name
      true -> "—"
    end
  end

  defp required_text(%{required_capabilities: caps}) when is_list(caps) and caps != [],
    do: Enum.join(caps, ", ")

  defp required_text(_), do: "—"

  defp eligible_text(%{eligible_offices: offices}) when is_list(offices) and offices != [],
    do: Enum.join(offices, ", ")

  defp eligible_text(_), do: "none"

  defp chosen_text(%{chosen_office_name: name}) when is_binary(name), do: name
  defp chosen_text(_), do: "No office"

  defp accepted_by_text(%{accepted_by: who}) when is_binary(who) and who != "", do: who
  defp accepted_by_text(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Routing decisions
        <:subtitle>
          An audit log of every routing decision the accept flow has made and why.
        </:subtitle>
      </.header>

      <.table id="routing-decisions" rows={@streams.decisions}>
        <:col :let={{_id, d}} label="When">
          {Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
        </:col>
        <:col :let={{_id, d}} label="Patient">{decision_patient(d)}</:col>
        <:col :let={{_id, d}} label="Required">{required_text(d)}</:col>
        <:col :let={{_id, d}} label="Eligible offices">{eligible_text(d)}</:col>
        <:col :let={{_id, d}} label="Chosen">{chosen_text(d)}</:col>
        <:col :let={{_id, d}} label="Accepted by">{accepted_by_text(d)}</:col>
        <:col :let={{_id, d}} label="Rationale">{d.rationale}</:col>
      </.table>
    </Layouts.app>
    """
  end
end
