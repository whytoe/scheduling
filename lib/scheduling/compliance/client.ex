defmodule Scheduling.Compliance.Client do
  @moduledoc """
  Thin HTTP client wrapping the intake-form-system REST API
  (`{INTAKE_API_URL}/openapi.json` describes it).

  Exposes `satisfied_refs/2`: given a patient's intake id and the compliance
  references an encounter requires, it returns the subset that already has a
  completed response on file. Scheduling compares that against what it required
  and decides — see `Scheduling.Compliance`.

  ## Why this shape, and not a verdict endpoint

  We originally asked intake for `GET /compliance/status` returning
  pass/fail. They declined, correctly, for two reasons worth keeping written
  down (`docs/intake-compliance-reply.md`):

    * The policy — *which* forms an encounter requires — is scheduling's. A
      verdict endpoint would have made intake the authority on a decision whose
      inputs (diagnosis, appointment, queue) it cannot see.
    * A bare pass/fail cannot be explained at a front desk. Knowing *which*
      requirement is outstanding is what lets someone tell the patient what to
      do about it.

  So intake answers a factual question about its own data and scheduling keeps
  the verdict. References are random per `(organization_id, form_type)` and
  opaque here — not a hash of the form-type name, so they cannot be recovered
  by guessing plausible names.

  ## One request per reference, for now

  `satisfied_refs/2` takes a list because the batch shape is what we want, but
  it currently issues one request per reference. Batching needs intake to
  return the reference on each row; without that a multi-ref query says how
  many requirements are met but not which, and "one of your two is satisfied"
  is not an answer the gate can use. The interface is already list-shaped so
  swapping in a real batch call is a change to this function alone.

  ## Proving the filter is a filter

  `satisfied_refs/2` reads only the row count, so it cannot tell a filtered
  answer from an unfiltered one — and an intake that accepts `compliance_ref`
  and ignores it turns every query into *"has this patient completed any form
  at all"*. `probe_ref_filter/0` is what settles that question; see
  `Scheduling.Compliance.FilterCheck` for when it runs and what is done with
  the answer.

  Configuration lives under `config :scheduling, Scheduling.Compliance` —
  `base_url`, `api_key`, `http_timeout_ms`.
  """

  @typedoc """
  `:unknown_reference` is separated from every other failure on purpose. It
  means intake did not recognise a reference we sent, which is a configuration
  fault on our side — a stale `cref_` left behind after a form type was
  retired. It must not be reported as a patient missing paperwork.
  """
  @type error :: {:unknown_reference, String.t()} | term()

  @doc """
  Returns `{:ok, MapSet.t()}` of the references that have a completed response
  on file for this patient, or `{:error, reason}`.

  A reference intake does not recognise fails the whole call rather than being
  treated as unsatisfied: a reference we cannot resolve must not silently
  block, nor silently pass.
  """
  @spec satisfied_refs(String.t(), [String.t()]) :: {:ok, MapSet.t()} | {:error, error()}
  def satisfied_refs(patient_id, refs) when is_binary(patient_id) and is_list(refs) do
    config = config()

    case config.api_key do
      nil ->
        {:error, :api_key_missing}

      key ->
        refs
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, MapSet.new()}, fn ref, {:ok, acc} ->
          case completed?(config, key, patient_id, ref) do
            {:ok, true} -> {:cont, {:ok, MapSet.put(acc, ref)}}
            {:ok, false} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  The base URL requests are currently sent to, so a cached fact about one
  intake deployment is not carried over to another.
  """
  @spec base_url() :: String.t()
  def base_url, do: config().base_url

  @doc """
  How long a single request to intake is allowed to take.
  """
  @spec http_timeout_ms() :: pos_integer()
  def http_timeout_ms, do: config().http_timeout_ms

  @doc """
  Asks intake a question that can only honestly be answered "nothing", and
  reports whether it was answered that way.

  The query carries a freshly minted `cref_` that intake has never issued, so
  no response on file can possibly carry it. Rows come back anyway only if
  `compliance_ref` is not narrowing the query.

  ## What each answer means

    * `400` — intake refused to resolve the reference. That is the behaviour
      settled in the `sc-s9x` exchange (`docs/intake-compliance-reply.md`) and
      it is positive proof the parameter reached a lookup. Because a `400` can
      equally mean "this query is malformed for reasons that have nothing to do
      with the reference", the same query is then repeated *without*
      `compliance_ref`: only if that one succeeds was the refusal about the
      reference.
    * `200` with no rows — consistent with the filter being applied. Weaker
      evidence than the `400`: an intake holding no completed responses at all
      answers identically. That is tolerable because the failure it can mask is
      one where every real query also returns nothing and the gate blocks
      rather than passes, and because the answer is re-established on a timer
      rather than kept forever (`Scheduling.Compliance.FilterCheck`).
    * `200` with rows — `compliance_ref` is not being applied. The gate cannot
      run.

  ## No `patient_id`

  Deliberately absent, though every real query carries one. The probe's whole
  job is to find out whether `compliance_ref` narrows anything, and a second
  narrowing parameter would let an intake that ignores the reference still
  answer with an empty list. Leaving it off makes the impossible reference the
  only thing that can produce an empty answer.

  ## Reasons never carry a body

  Every error returned here names a status or a transport failure and nothing
  else. The control query above is unscoped by patient, so its body may hold
  other people's response rows — and this reason travels into a
  `routing_decisions` rationale, which is append-only and is returned by
  `GET /api/v1/routing_decisions` to any token with a read role.

  Not webhooks, despite the obvious assumption: `Webhooks.dispatch/1` is called
  from `Audit.record_event/1` and never from `record_decision/3`. The row is
  still readable by every integrator, which is enough.
  """
  @spec probe_ref_filter() :: :ok | {:error, term()}
  def probe_ref_filter do
    config = config()

    case config.api_key do
      nil -> {:error, :api_key_missing}
      key -> probe(config, key)
    end
  end

  defp probe(config, key) do
    case probe_request(config, key,
           compliance_ref: impossible_ref(),
           status: "completed",
           limit: 1
         ) do
      {:ok, %{status: 200, body: body}} ->
        case rows(body) do
          nil -> {:error, :probe_unexpected_body}
          [] -> :ok
          [_ | _] -> {:error, :ref_filter_not_applied}
        end

      # Ambiguous on its own — establish whether the reference was the reason.
      {:ok, %{status: 400}} ->
        control(config, key)

      {:ok, %{status: status}} ->
        {:error, {:probe_status, status}}

      {:error, exception} ->
        {:error, {:probe_transport, transport_reason(exception)}}
    end
  end

  # The same query minus the reference. A 400 here too means the refusal was
  # never about the reference, so the probe has established nothing.
  defp control(config, key) do
    case probe_request(config, key, status: "completed", limit: 1) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 400}} -> {:error, :probe_inconclusive}
      {:ok, %{status: status}} -> {:error, {:probe_control_status, status}}
      {:error, exception} -> {:error, {:probe_transport, transport_reason(exception)}}
    end
  end

  # Shaped like a reference intake mints (`cref_` + random hex) so it exercises
  # the lookup rather than the validator, and random per probe so it cannot
  # collide with one intake issues later.
  defp impossible_ref, do: "cref_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Exceptions carry a URL and sometimes a response body; only the reason is
  # safe to hand onwards. See the note on bodies in `probe_ref_filter/0`.
  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(%struct{}), do: struct
  defp transport_reason(_other), do: :unknown

  defp completed?(config, key, patient_id, ref) do
    config
    |> request(
      key,
      [patient_id: patient_id, compliance_ref: ref, status: "completed", limit: 1],
      retry: :safe_transient
    )
    |> handle_response(ref)
  end

  # `retry: false` on the probe, unlike the real queries. Req's default backoff
  # spends seconds on an intake that is down, and the probe is serialised
  # through `Scheduling.Compliance.FilterCheck` — so retrying inside it holds
  # every other accept behind a failure that is already going to be retried on
  # the next accept anyway.
  defp probe_request(config, key, params), do: request(config, key, params, retry: false)

  defp request(config, key, params, opts) do
    [
      url: config.base_url <> "/responses",
      params: params,
      headers: [{"authorization", "Bearer " <> key}],
      receive_timeout: config.http_timeout_ms
    ]
    |> Keyword.merge(opts)
    |> Req.new()
    |> Req.get()
  end

  # 400 is intake's answer for a reference it cannot resolve — agreed in
  # docs/intake-compliance-reply.md precisely so a retired reference is loud
  # rather than degrading to a skip.
  defp handle_response({:ok, %{status: 400}}, ref), do: {:error, {:unknown_reference, ref}}

  defp handle_response({:ok, %{status: 200, body: body}}, _ref) do
    case rows(body) do
      nil -> {:error, {:unexpected_body, shape(body)}}
      [] -> {:ok, false}
      [_ | _] -> {:ok, true}
    end
  end

  defp handle_response({:ok, %{status: status}}, _ref),
    do: {:error, {:http_status, status}}

  defp handle_response({:error, exception}, _ref), do: {:error, exception}

  # Describes a body without carrying any of it.
  #
  # These reasons are not private. `Scheduling.Queue` puts the reason into
  # `routing_decisions.rationale`, which is append-only, rendered at
  # `/decisions`, and returned by `GET /api/v1/routing_decisions` to any token
  # with a read role — `viewer` and `service` included. A body from intake's
  # `/responses` is a patient's form-response rows, so carrying it there put
  # health data into an audit row that cannot be edited or deleted.
  #
  # Shape is what a diagnosis actually needs: "intake answered with a map we
  # did not recognise" is the useful fact, and it is the whole useful fact. The
  # content is never required to tell that the envelope changed.
  #
  # Keys are deliberately NOT included, even though they would be handy. An
  # envelope keyed by identifier would make them data.
  # No list clause: `rows/1` returns a bare list as-is, so a list body never
  # reaches here.
  defp shape(body) when is_map(body), do: {:map, map_size(body)}
  defp shape(body) when is_binary(body), do: {:string, byte_size(body)}
  defp shape(nil), do: :nil_body
  defp shape(_other), do: :unrecognised

  # The list may arrive bare or wrapped; accept both rather than guess, since
  # the envelope is not fixed until intake ships this.
  defp rows(body) when is_list(body), do: body
  defp rows(%{"data" => rows}) when is_list(rows), do: rows
  defp rows(%{"responses" => rows}) when is_list(rows), do: rows
  defp rows(_body), do: nil

  defp config do
    raw = Application.get_env(:scheduling, Scheduling.Compliance) || []

    %{
      base_url: Keyword.get(raw, :base_url, "http://localhost:3001/api/v1"),
      api_key: Keyword.get(raw, :api_key),
      http_timeout_ms: Keyword.get(raw, :http_timeout_ms, 5_000)
    }
  end
end
