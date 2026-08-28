defmodule Scheduling.Auth.SessionRevocation do
  @moduledoc """
  Sessions the identity provider has told us to stop trusting.

  Our browser session is a signed cookie holding a compact identity and its own
  8h deadline (`Scheduling.Auth.session_ttl_seconds/0`). Nothing about that
  cookie changes when the operator signs out at the IdP, or when an
  administrator ends their session — so without this table a revoked session
  keeps working here for the rest of the day.
  `SchedulingWeb.AuthController.backchannel_logout/2` writes rows here; every
  request checks them via `SchedulingWeb.Plugs.BrowserAuth.scope_from_session/1`.

  ## Why Postgres and not ETS

  `DNSCluster` is configured, so this app can run as several nodes behind one
  hostname. The IdP delivers a logout notification to *one* of them. An
  in-memory table would revoke the session on that node and leave it live on
  every other — which is the same as not revoking it at all.

  ## Two kinds of row

  Back-channel logout tokens identify what to end with a `sid`, a `sub`, or
  both (OpenID Connect Back-Channel Logout 1.0 §2.4):

    * `"sid"` — one session. What ac-core sends; it advertises
      `backchannel_logout_session_supported: true`.
    * `"sub"` — every session that subject has here. This is the
      "sign this person out everywhere" case, and a `sid`-only store would
      silently ignore it.

  ## Expiry

  `expires_at` is when the revoked session *would have lapsed anyway*, so a
  row is worthless past it and `sweep/0` drops it. Deleting a stale row cannot
  resurrect a session: `scope_from_session/1` independently rejects an
  identity whose own `exp` has passed, and that happens no later.
  """

  import Ecto.Query, warn: false

  alias Scheduling.Auth
  alias Scheduling.Auth.Identity
  alias Scheduling.Repo

  @table "revoked_sessions"

  @typedoc "What the revocation is keyed on. See the module doc."
  @type kind :: :sid | :sub

  @doc """
  Records a revocation, valid until the session it names would have expired.

  Upserts, because a logout notification may be delivered more than once and a
  duplicate must not be an error.
  """
  @spec revoke(kind(), String.t()) :: :ok
  def revoke(kind, value) when kind in [:sid, :sub] and is_binary(value) and value != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, Auth.session_ttl_seconds(), :second)

    Repo.insert_all(
      @table,
      [
        [
          kind: Atom.to_string(kind),
          value: value,
          expires_at: expires_at,
          inserted_at: now,
          updated_at: now
        ]
      ],
      on_conflict: [set: [expires_at: expires_at, updated_at: now]],
      conflict_target: [:kind, :value]
    )

    :ok
  end

  @doc """
  True when this identity's session has been revoked — either the session
  itself (`sid`) or its subject wholesale (`sub`).
  """
  @spec revoked?(Identity.t()) :: boolean()
  def revoked?(%Identity{} = identity) do
    keys =
      [{"sid", identity.sid}, {"sub", identity.subject}]
      |> Enum.reject(fn {_kind, value} -> value in [nil, ""] end)

    case keys do
      [] ->
        false

      keys ->
        conditions =
          Enum.reduce(keys, dynamic(false), fn {kind, value}, acc ->
            dynamic([r], ^acc or (r.kind == ^kind and r.value == ^value))
          end)

        Repo.exists?(from(r in @table, where: ^conditions))
    end
  end

  @doc """
  Drops rows whose session would have expired anyway. Pure hygiene — see the
  module doc on why it cannot un-revoke anything. Returns the number removed.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = DateTime.utc_now()
    {deleted, _} = Repo.delete_all(from(r in @table, where: r.expires_at <= ^now))
    deleted
  end
end
