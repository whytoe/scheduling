defmodule SchedulingWeb.Plugs.RateLimit do
  @moduledoc """
  Counts API requests per bearer token and refuses the excess with `429`.

  Runs **before** `SchedulingWeb.Plugs.ApiAuth`, which is the whole point.
  ac-core issues opaque tokens, so a bearer token that fails JWT validation
  costs an introspection round-trip measured at 1.3–1.7 seconds, and a refusal
  is deliberately never cached. Placing the limit after authentication would
  leave exactly the expensive path unprotected — an attacker with one invalid
  token could hold requests open indefinitely.

  See `Scheduling.RateLimit` for why the key is the token's digest rather than
  the caller's IP or subject.

  A request with no `Authorization` header passes straight through. It is
  refused immediately by `ApiAuth` without asking the provider anything, so it
  is cheap and needs no quota.

  `429` carries `Retry-After` in seconds, per RFC 9110 — a client that honours
  it backs off correctly instead of guessing, which is the difference between a
  limiter that calms a retry storm and one that shapes it.
  """

  @behaviour Plug

  import Plug.Conn

  alias Scheduling.RateLimit
  alias SchedulingWeb.ErrorEnvelope

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with true <- RateLimit.enabled?(),
         [<<"Bearer ", token::binary>>] <- get_req_header(conn, "authorization"),
         {:error, {:rate_limited, retry_after}} <- RateLimit.check(RateLimit.key_for_token(token)) do
      refuse(conn, retry_after)
    else
      _allowed -> conn
    end
  end

  defp refuse(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(
        ErrorEnvelope.error_envelope(
          "rate_limited",
          "Too many requests. Retry in #{retry_after}s.",
          %{retry_after_seconds: retry_after}
        )
      )
    )
    |> halt()
  end
end
