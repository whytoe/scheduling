defmodule Scheduling.Compliance.FilterCheck do
  @moduledoc """
  Establishes that intake is really filtering by `compliance_ref` before the
  compliance gate is allowed to reach a verdict.

  ## The exposure this closes

  `Scheduling.Compliance.Client.satisfied_refs/2` sends four query parameters
  and reads only the **row count**. Nothing in that answer says which of the
  four intake honoured. If `compliance_ref` is accepted and ignored, the query
  quietly becomes *"has this patient completed any form at all"*, and a patient
  who filled in something unrelated satisfies every requirement on the entry.
  If `patient_id` were the ignored one instead, any patient in the organisation
  completing that form would satisfy it for everyone.

  Both directions fail **open**, silently, on the exact path the gate exists to
  close. Nothing errors and nothing logs. That is the whole problem: the
  reassuring answer and the broken answer are the same bytes.

  `Client.probe_ref_filter/0` tells them apart by asking a question whose only
  honest answer is "nothing" — a reference intake has never minted. This module
  decides when to ask it, remembers the answer, and turns a bad one into a
  refusal.

  ## Refuse, do not pass

  A probe that does not come back clean makes `Scheduling.Compliance.verify/1`
  return an error rather than a verdict. The accept flow renders that as `503
  compliance_unavailable` and the entry stays waiting — the same fail-closed
  path an unreachable intake already takes.

  Refusing to run is the point. The alternative is running a gate we cannot
  show is gating anything, which is worse than having no gate at all: it looks
  like a control on the deployment checklist while passing everyone.

  ## On first use, not at boot

  The probe runs on the first `verify/1` that would actually consult intake,
  not when the release starts.

  Booting into it would make intake's availability a startup dependency of
  scheduling. A release that cannot reach intake for the thirty seconds after a
  pod restart would either crash out or cache a failure it never retries —
  buying nothing, because the gate is not deciding anything until the first
  accept arrives anyway. Running it on first use puts the cost at the moment
  there is a real request to fail, and makes recovery automatic: the next
  accept re-probes.

  Per request was the other option and is the one the bead argued against. The
  condition does not change between two accepts a second apart, and paying for
  it twice per accept doubles our traffic to intake to re-establish a fact that
  did not move.

  ## Why the answer expires

  A verified answer is held for fifteen minutes and then re-established.

  Caching it for the life of the process would reproduce, one level up, the
  failure this module exists to catch: a reassuring signal that was true once
  and is never checked again. Two things can make it go stale without anything
  restarting here — intake rolling back the filter, and the weaker of the two
  pass conditions. `200` with no rows is consistent with the filter working and
  equally consistent with an intake holding no completed responses at all; the
  moment that intake records its first response, the same probe starts
  answering honestly. The expiry is what bounds how long a pass granted under
  those conditions survives.

  Failures are never cached, so a deployment that fixes intake recovers on the
  next accept without a restart.

  ## Keyed on the base URL

  A fact established about one intake deployment says nothing about another, so
  pointing `INTAKE_API_URL` somewhere else discards the answer rather than
  inheriting it.

  ## Started unconditionally

  Unlike the other optional processes in the supervision tree this one has no
  `child_spec_if_enabled/0`. It performs no work until something calls
  `verify/1`, and `Scheduling.Compliance.verify/1` only calls it once the gate
  is configured — so gating the process on the same configuration would buy
  nothing and add a way for the gate to be on while the check that guards it is
  absent.
  """

  use GenServer

  require Logger

  alias Scheduling.Compliance.Client

  # Long enough that the probe is noise next to normal gate traffic, short
  # enough that a pass granted by an empty intake does not outlive the day.
  @ttl_s 15 * 60

  @typedoc """
  The base URL the standing answer was established against, and the second it
  stops being served. Both `nil` means nothing is established.
  """
  @type state :: %{
          ttl_s: pos_integer(),
          base_url: String.t() | nil,
          verified_until: integer() | nil
        }

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  `:ok` when intake has been shown to apply `compliance_ref`, `{:error,
  reason}` when that could not be established.

  An error here means the gate must not reach a verdict. It is never a
  statement about a patient.
  """
  @spec verify(GenServer.server()) :: :ok | {:error, term()}
  def verify(server \\ __MODULE__) do
    # The probe may make two requests, and a caller that gives up before the
    # process does would re-probe on the next accept for no reason.
    GenServer.call(server, :verify, 2 * Client.http_timeout_ms() + 2_000)
  catch
    :exit, {:noproc, _} -> {:error, :filter_check_not_started}
    :exit, {:timeout, _} -> {:error, :filter_check_timeout}
  end

  @doc """
  Discards the standing answer so the next `verify/1` establishes it again.

  For the case where intake is known to have changed under us and waiting out
  the expiry is not wanted.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{ttl_s: Keyword.get(opts, :ttl_s, @ttl_s), base_url: nil, verified_until: nil}}
  end

  @impl GenServer
  def handle_call(:verify, _from, state) do
    base_url = Client.base_url()

    if standing?(state, base_url) do
      {:reply, :ok, state}
    else
      case Client.probe_ref_filter() do
        :ok ->
          {:reply, :ok, %{state | base_url: base_url, verified_until: now() + state.ttl_s}}

        {:error, reason} = error ->
          log_refusal(base_url, reason)
          {:reply, error, %{state | base_url: nil, verified_until: nil}}
      end
    end
  end

  @impl GenServer
  def handle_cast(:invalidate, state) do
    {:noreply, %{state | base_url: nil, verified_until: nil}}
  end

  defp standing?(%{base_url: cached, verified_until: until}, base_url)
       when is_binary(cached) and is_integer(until),
       do: cached == base_url and now() < until

  defp standing?(_state, _base_url), do: false

  # Loud on purpose, and at :error rather than :warning. Every accept that
  # needed the gate is now being refused, and the cause is a configuration or
  # deployment mismatch that no amount of waiting fixes.
  #
  # Carries no patient id and no response body — see the note on reasons in
  # `Client.probe_ref_filter/0`.
  defp log_refusal(base_url, :ref_filter_not_applied) do
    Logger.error("""
    Compliance gate REFUSING TO RUN: #{base_url} returned rows for a compliance \
    reference that has never been minted, so `compliance_ref` is not filtering \
    anything. Every query the gate makes would degrade to "has this patient \
    completed any form at all" and every patient would pass.

    Accepts that require compliance will fail closed until this is fixed. Either \
    the filter is not deployed at this intake, or INTAKE_API_URL points at an \
    intake that predates it.
    """)
  end

  defp log_refusal(base_url, reason) do
    Logger.error(
      "Compliance gate REFUSING TO RUN: could not establish that #{base_url} applies " <>
        "`compliance_ref` (#{inspect(reason)}). Accepts that require compliance fail closed " <>
        "until it can be."
    )
  end

  defp now, do: System.system_time(:second)
end
