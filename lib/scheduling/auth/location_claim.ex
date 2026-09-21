defmodule Scheduling.Auth.LocationClaim do
  @moduledoc """
  One-shot observation of the `astrum_location` claim on a real browser login,
  to settle sc-24q.

  Per-office scoping shipped defaulting PERMISSIVE, on three unknowns that only
  a real ac-core token answers:

    1. does ac-core populate `astrum_location` at all;
    2. a single id, or a list;
    3. what a user with **no** site assignment carries — the claim absent, or
       an empty value.

  Question 3 is the one that matters: `location_ids/1` folds absent, `""` and
  `[]` all into `nil` — the right runtime default (an empty scope must not lock
  a user out of every office; see `Scheduling.Auth.location_claim/0`) but it
  erases exactly the distinction needed to confirm the default is safe. So the
  `Identity` struct cannot answer this after the fact; the raw claim has to be
  read at the callback, before it is normalised. That is what this does — one
  log line per login, from `SchedulingWeb.AuthController`.

  It also checks the ids against `locations.core_location_id`, because the
  sharpest unknown is not the shape but the id *space*: the claim is matched
  against `locations.core_location_id`, and if ac-core issues location ids from
  a different space than the sync writes there, every scoped operator sees only
  unlinked offices — a short board, not an error, indistinguishable at a glance
  from an empty `locations` table. The match count turns that silent failure
  into a line in the log the first time a real scoped user signs in.

  Diagnostic only: it makes no authorization decision, changes no state, and is
  wrapped so it can never fail a sign-in. Remove it — with the `observe/1` call
  in `SchedulingWeb.AuthController` — once docs/auth.md 'Per-office access'
  stops hedging.
  """

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Locations

  @doc """
  Logs what the `astrum_location` claim looks like on this login's ID token.

  Reads the claim from the ID-token claims map, which is the only place the
  browser identity reads location from (`Scheduling.Auth.Tokens.identity_from_login/1`
  merges only *role* claims off the access token). So "absent" here means
  absent from the ID token specifically: if ac-core turns out to put the claim
  on the access token instead — as Keycloak does with roles — that is the next
  thing to check, and it would need the same merge treatment roles get.

  Always returns `:ok`; a diagnostic must never be the reason a login fails.
  """
  @spec observe(term()) :: :ok
  def observe(claims) when is_map(claims) do
    claim = Auth.location_claim()
    Logger.info("astrum_location observation — #{claim}: #{describe(Map.fetch(claims, claim))}")
    :ok
  rescue
    error ->
      Logger.warning("astrum_location observation failed: #{inspect(error)}")
      :ok
  end

  def observe(_claims), do: :ok

  # oidcc decodes a JSON null to the atom `:null`, not `nil` — matched here so a
  # provider that sends `"astrum_location": null` is reported as such rather
  # than lumped in with the value shapes below.
  defp describe(:error), do: "absent from the ID token (no key)"
  defp describe({:ok, :null}), do: "present, JSON null"
  defp describe({:ok, ""}), do: "present, empty string"
  defp describe({:ok, []}), do: "present, empty list"

  defp describe({:ok, value}) when is_binary(value) do
    "single id #{inspect(value)}#{match_note([value])}"
  end

  defp describe({:ok, values}) when is_list(values) do
    ids = Enum.filter(values, &is_binary/1)
    "list of #{length(values)} #{inspect(values)}#{match_note(ids)}"
  end

  defp describe({:ok, other}), do: "unexpected shape #{inspect(other)}"

  # Do these ids name locations we actually hold? The claim is matched against
  # `locations.core_location_id`; nothing matching means the two are different
  # id spaces, which is the silent short-board failure this observation exists
  # to catch.
  defp match_note([]), do: ""

  defp match_note(ids) do
    matched = Enum.count(ids, &(Locations.get_by_core_location_id(&1) != nil))
    " — #{matched}/#{length(ids)} match locations.core_location_id"
  end
end
