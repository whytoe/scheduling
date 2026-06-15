defmodule SchedulingWeb.EventTimeline do
  @moduledoc """
  Presentation mapping shared by `/visit_events` and `/visits`: turns stored
  `Scheduling.Audit.VisitEvent` records into the view maps the `timeline/1`
  component renders (label + icon + tone + actor + note).
  """

  # type => {label, icon, tone}
  @event_meta %{
    "queue_entry.created" => {"Signed in", "hero-arrow-right-circle", "assigned"},
    "queue_entry.completed" => {"Completed", "hero-check-circle", "success"},
    "handoff.acknowledged" => {"Handoff acknowledged", "hero-hand-raised", "active"},
    "visit.created" => {"Visit opened", "hero-arrow-right-circle", "assigned"},
    "visit.ended" => {"Visit ended", "hero-check-circle", "success"}
  }

  @event_note %{
    "queue_entry.created" => "Joined the waiting queue",
    "queue_entry.completed" => "Service completed · capacity freed",
    "handoff.acknowledged" => "Acknowledged by clinical staff",
    "visit.created" => "Visit opened",
    "visit.ended" => "Visit ended"
  }

  @doc "Maps a list of events to chronological (oldest-first) view maps."
  def view_events(events) do
    events
    |> Enum.sort_by(& &1.occurred_at, DateTime)
    |> Enum.map(&view_event/1)
  end

  @doc "Maps a single event to a timeline view map."
  def view_event(e) do
    {label, icon, tone} =
      Map.get(@event_meta, e.type, {humanize(e.type), "hero-clock", "neutral"})

    %{
      label: label,
      icon: icon,
      tone: tone,
      time: Calendar.strftime(e.occurred_at, "%H:%M:%S"),
      actor: actor_key(e.actor_type),
      note: Map.get(@event_note, e.type)
    }
  end

  @doc "Derives a lifecycle status key from a set of event types."
  def derive_status(types) do
    cond do
      "queue_entry.completed" in types or "visit.ended" in types -> "completed"
      "handoff.acknowledged" in types -> "in_service"
      true -> "waiting"
    end
  end

  defp humanize(type), do: type |> String.replace([".", "_"], " ") |> String.capitalize()

  # Map stored actor_type values onto the actor vocabulary.
  def actor_key("clinical"), do: "clinician"
  def actor_key(t) when t in ["front_desk", "clinician", "queueing", "system"], do: t
  def actor_key(_), do: "system"
end
