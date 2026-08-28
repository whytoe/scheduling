defmodule Scheduling.Auth.Provider do
  @moduledoc """
  Supervision-tree entry for the OIDC provider configuration worker.

  `Oidcc.ProviderConfiguration.Worker` fetches the issuer's
  `.well-known/openid-configuration` and JWKS at boot, then refreshes them on
  the document's own cadence and on demand when a token arrives signed by an
  unknown `kid` (key rotation). Every token validation in the app reads the
  keys from this worker rather than fetching them itself.

  When auth is not configured the worker is simply absent from the tree — it
  cannot start without an issuer to discover, and `Scheduling.Auth.enabled?/0`
  keeps anything from asking for it.

  `backoff_*` is set because the IdP and the app usually boot together: a
  realm that is not yet serving discovery should cause a retry, not take the
  supervisor down with it.
  """

  alias Scheduling.Auth

  @doc """
  Child spec for the provider worker, or `nil` when auth is disabled.

  `Scheduling.Application` filters the nil out.
  """
  @spec child_spec_if_enabled() :: Supervisor.child_spec() | nil
  def child_spec_if_enabled do
    if Auth.enabled?() do
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: Auth.issuer(),
         name: Auth.provider_name(),
         provider_configuration_opts: provider_configuration_opts(),
         backoff_min: 1_000,
         backoff_max: 30_000,
         backoff_type: :exponential
       }}
    end
  end

  @doc """
  Options passed to discovery. `document_overrides` fills in fields the
  provider omits — see `Scheduling.Auth.discovery_overrides/0` for why that is
  needed at all and when it should go away.
  """
  @spec provider_configuration_opts() :: map()
  def provider_configuration_opts do
    case Auth.discovery_overrides() do
      overrides when overrides == %{} -> %{}
      overrides -> %{quirks: %{document_overrides: overrides}}
    end
  end

  @doc """
  Builds the `Oidcc.ClientContext` used for every token operation — it pairs
  the discovered provider configuration and JWKS with this app's credentials.
  """
  @spec client_context() :: {:ok, Oidcc.ClientContext.t()} | {:error, term()}
  def client_context do
    Oidcc.ClientContext.from_configuration_worker(
      Auth.provider_name(),
      Auth.client_id(),
      Auth.client_secret()
    )
  end
end
