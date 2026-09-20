defmodule SchedulingWeb.Plugs.Idempotency do
  @moduledoc """
  Honours the `Idempotency-Key` request header on writes.

  A caller that repeats a request with the same key gets the **first call's
  response** back, rather than the write happening twice. See
  `Scheduling.Idempotency` for the storage rules and why `5xx` is excluded.

  ## Opt-in, deliberately

  A request without the header passes straight through. Requiring the header
  would break every existing integrator at once to protect them from a problem
  they may not have, and a caller who has thought about retries is exactly the
  caller who will send it. Absence is a decision by the client, not an
  oversight for us to correct.

  ## Responses it adds

  | Case | Status | `error.code` |
  |---|---|---|
  | Same key, request still in flight | 409 | `idempotency_key_in_progress` |
  | Same key, different request | 422 | `idempotency_key_reuse` |

  The split matters to a client: 409 means *wait and try again*, 422 means
  *your request is wrong and retrying will not help*.

  A replayed response carries `idempotency-replayed: true`, so a caller can
  tell a cached answer from a fresh one without diffing bodies.
  """

  @behaviour Plug

  import Plug.Conn

  alias Scheduling.Auth.Identity
  alias Scheduling.Idempotency
  alias SchedulingWeb.ErrorEnvelope

  @header "idempotency-key"
  @max_key_length 255

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, @header) do
      [key] when byte_size(key) > 0 and byte_size(key) <= @max_key_length ->
        apply_key(conn, key)

      [] ->
        conn

      _other ->
        # Absent is fine; malformed is not. An over-long or repeated header is
        # a client bug, and silently ignoring it would leave them believing
        # they had retry protection they do not have.
        refuse(conn, 422, "idempotency_key_invalid", "The Idempotency-Key header is not usable.")
    end
  end

  defp apply_key(conn, key) do
    caller = caller(conn)
    fingerprint = Idempotency.fingerprint(conn.method, conn.request_path, conn.body_params)

    case Idempotency.claim(caller, key, fingerprint) do
      {:claimed, claimed} ->
        register_before_send(conn, &settle(&1, claimed))

      {:replay, settled} ->
        replay(conn, settled)

      :in_progress ->
        refuse(
          conn,
          409,
          "idempotency_key_in_progress",
          "A request with this Idempotency-Key is still being processed. Retry shortly."
        )

      {:mismatch, _existing} ->
        refuse(
          conn,
          422,
          "idempotency_key_reuse",
          "This Idempotency-Key was used for a different request. Use a new key."
        )
    end
  end

  defp settle(conn, claimed) do
    content_type = conn |> get_resp_header("content-type") |> List.first()

    Idempotency.settle(
      claimed,
      conn.status,
      IO.iodata_to_binary(conn.resp_body || ""),
      content_type
    )

    conn
  end

  defp replay(conn, settled) do
    conn
    |> put_resp_content_type_from(settled.response_content_type)
    |> put_resp_header("idempotency-replayed", "true")
    |> send_resp(settled.response_status, settled.response_body || "")
    |> halt()
  end

  defp put_resp_content_type_from(conn, nil), do: put_resp_content_type(conn, "application/json")
  defp put_resp_content_type_from(conn, type), do: put_resp_header(conn, "content-type", type)

  # Keyed by who is calling, so two services picking the same UUID do not
  # collide and neither can read back the other's response. Without a token
  # there is nobody to attribute it to; "anonymous" shares one namespace, which
  # is acceptable only because that is the auth-disabled local-dev case.
  defp caller(conn) do
    case conn.assigns[:current_identity] do
      %Identity{} = identity ->
        {type, id} = Identity.actor(identity)
        "#{type}:#{id}"

      nil ->
        "anonymous"
    end
  end

  defp refuse(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(ErrorEnvelope.error_envelope(code, message)))
    |> halt()
  end
end
