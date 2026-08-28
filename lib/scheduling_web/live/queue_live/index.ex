defmodule SchedulingWeb.QueueLive.Index do
  @moduledoc """
  The receptionist's keyboard-first accept queue. Arrow keys (or j/k) move the
  roving selection, Enter/Space accepts the focused row — the matcher routes to
  the best-fit office. A sticky routing preview mirrors `Scheduling.Matching`
  and shows the chosen office and every eligible office *before* the operator
  commits, so a bad route can be caught in advance. We never auto-submit.
  """
  use SchedulingWeb, :live_view

  alias Scheduling.Matching
  alias Scheduling.Matching.{Candidate, Result}
  alias Scheduling.Offices
  alias Scheduling.Queue

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Accept queue")
     |> assign(:selected, nil)
     |> load_waiting()}
  end

  @impl true
  def handle_event("select", %{"id" => nil}, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, build_preview(id))}
  end

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
         |> assign(:selected, nil)
         |> stream_delete(:waiting, entry)
         |> recount()}

      {:no_eligible_office, %Result{} = result} ->
        {:noreply, put_flash(socket, :error, result.rationale)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not accept this patient — please refresh and retry.")}
    end
  end

  defp load_waiting(socket) do
    waiting = Queue.list_waiting_entries() |> Scheduling.Repo.preload(:diagnosis)

    # Pre-select the top of the queue so the routing preview is populated on
    # first paint (and without JS); the hook then drives selection client-side.
    selected =
      case waiting do
        [first | _] -> build_preview(first.id)
        [] -> nil
      end

    socket
    |> assign(:waiting_count, length(waiting))
    |> assign(:selected, selected)
    |> stream(:waiting, waiting, reset: true)
  end

  defp recount(socket) do
    update(socket, :waiting_count, fn n -> max(n - 1, 0) end)
  end

  # Builds the routing preview for a single entry without committing, using the
  # same matcher the accept path runs.
  defp build_preview(id) do
    entry = Queue.get_entry!(id)
    loads = Queue.current_loads()
    offices = Offices.list_offices()
    result = Matching.match_queue_entry(entry, loads)

    %{
      name: patient_name(entry),
      required: required_names(entry),
      chosen: chosen_preview(result.chosen),
      eligible: Enum.map(result.eligible, &candidate_preview/1),
      missing: missing_capabilities(entry, offices)
    }
  end

  defp chosen_preview(nil), do: nil
  defp chosen_preview(%Candidate{} = c), do: candidate_preview(c)

  defp candidate_preview(%Candidate{office: office, surplus: surplus, free_capacity: free}) do
    %{name: office.name, surplus: surplus, free: free}
  end

  # Required capability names this set of offices cannot provide at all.
  defp missing_capabilities(entry, offices) do
    provided =
      offices
      |> Enum.flat_map(fn o -> Enum.map(o.capabilities, & &1.name) end)
      |> MapSet.new()

    entry
    |> required_caps()
    |> Enum.reject(&MapSet.member?(provided, &1))
  end

  defp required_caps(entry) do
    case entry.required_capabilities do
      caps when is_list(caps) -> caps |> Enum.map(& &1.name) |> Enum.sort()
      _ -> []
    end
  end

  defp required_names(entry) do
    case required_caps(entry) do
      [] -> []
      caps -> caps
    end
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

  defp eligibility_detail(%Result{eligible: []}), do: ""

  defp eligibility_detail(%Result{eligible: candidates}) do
    detail =
      candidates
      |> Enum.map(fn c -> "#{c.office.name} (#{c.free_capacity} free, #{c.surplus} surplus)" end)
      |> Enum.join("; ")

    " Eligible: #{detail}."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:queue} wide>
      <.page_head title="Accept queue">
        <:subtitle>
          Keyboard-first. Arrow keys move the selection, Enter accepts — the matcher
          routes to the best-fit office. No mouse required.
        </:subtitle>
      </.page_head>

      <div class="cols cols--2" style="align-items:start">
        <%!-- QUEUE LIST --%>
        <section aria-labelledby="queue-heading">
          <.zone_head
            id="queue-heading"
            count_id="queue-count"
            icon="hero-queue-list"
            title="Waiting patients"
            count={@waiting_count}
          >
            <:right>
              <div class="flex items-center gap-[6px] t-small">
                <kbd class="kbd">↑</kbd><kbd class="kbd">↓</kbd>
                <span>move</span>
                <kbd class="kbd">Enter</kbd>
                <span>accept</span>
              </div>
            </:right>
          </.zone_head>

          <div :if={@waiting_count == 0} class="card">
            <.empty_state icon="hero-check-circle" title="Queue is empty">
              Every waiting patient has been accepted. New sign-ins appear here automatically.
            </.empty_state>
          </div>

          <div
            :if={@waiting_count > 0}
            id="queue-list"
            class="stack"
            role="listbox"
            aria-label="Waiting patients"
            phx-hook="QueueList"
            phx-update="stream"
          >
            <div
              :for={{dom_id, entry} <- @streams.waiting}
              id={dom_id}
              role="option"
              data-id={entry.id}
              tabindex="-1"
              aria-selected="false"
              class="pcard qrow"
            >
              <.priority_tag priority={entry.priority} />
              <div class="pcard__main">
                <div class="pcard__name">{patient_name(entry)}</div>
                <div class="pcard__meta">
                  <span :if={diagnosis_name(entry)} class="t-small">{diagnosis_name(entry)}</span>
                  <.cap_row caps={required_caps(entry)} />
                </div>
              </div>
              <div class="pcard__side">
                <button
                  type="button"
                  class="btn btn-primary btn-clinical"
                  data-accept
                  phx-click={JS.push("accept", value: %{id: entry.id})}
                  aria-label={"Accept #{patient_name(entry)}"}
                >
                  <.icon name="hero-check" class="size-5" />Accept
                </button>
              </div>
            </div>
          </div>
        </section>

        <%!-- ROUTING PREVIEW --%>
        <aside class="sticky-preview" aria-live="polite" aria-label="Routing preview">
          <.zone_head icon="hero-sparkles" title="Routing preview" />
          <div class="card card__body">
            <p :if={@selected == nil} class="t-small">Select a patient to preview routing.</p>

            <.callout
              :if={@selected != nil and @selected.chosen == nil}
              tone="attention"
              title="No eligible office"
            >
              <span :if={@selected.missing != []}>
                No office provides <b>{Enum.join(@selected.missing, ", ")}</b> with free capacity.
              </span>
              <span :if={@selected.missing == []}>
                No eligible office has free capacity for these requirements right now.
              </span>
              Accept is blocked; the failure is logged to <b>Decisions</b>.
            </.callout>

            <div :if={@selected != nil and @selected.chosen != nil}>
              <div class="t-small">Best fit for</div>
              <div class="pcard__name" style="margin-bottom:var(--s-3)">{@selected.name}</div>

              <div style="padding:var(--s-3);border-radius:var(--radius-field);background:var(--st-assigned-bg);border:1px solid var(--st-assigned-line);margin-bottom:var(--s-3)">
                <div class="flex justify-between items-center">
                  <span style="font-weight:600;color:var(--st-assigned-fg)">
                    {@selected.chosen.name}
                  </span>
                  <.status_badge status="assigned" label="Will route here" />
                </div>
                <div class="t-small" style="margin-top:4px">
                  {@selected.chosen.surplus} surplus {pluralize(
                    @selected.chosen.surplus,
                    "capability",
                    "capabilities"
                  )} · {@selected.chosen.free} free {pluralize(@selected.chosen.free, "slot", "slots")}
                </div>
              </div>

              <div class="t-label" style="margin-bottom:6px">
                {length(@selected.eligible)} eligible
              </div>
              <div class="stack">
                <div
                  :for={{e, i} <- Enum.with_index(@selected.eligible)}
                  class="flex justify-between text-[13px]"
                  style={
                    (i == 0 && "color:var(--color-base-content)") ||
                      "color:var(--color-base-content-muted)"
                  }
                >
                  <span>{e.name}</span>
                  <span class="tnum">{e.free} free · {e.surplus} surplus</span>
                </div>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural
end
