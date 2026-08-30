defmodule Scheduling.ServiceTokenStub do
  @moduledoc """
  Stands in for `Scheduling.Auth.ServiceToken` in tests of things that *use* a
  core API token, so those tests exercise the caller rather than the token
  cache. `ServiceToken` has its own tests.

  It registers under the real module's name, so a caller's `GenServer.call`
  reaches this instead. Start it with the reply you want every `fetch/0` to
  produce:

      setup do
        start_supervised!({Scheduling.ServiceTokenStub, {:ok, "a-token"}})
        :ok
      end

  Note `ServiceToken.fetch/0` short-circuits on `Scheduling.Core.enabled?/0`
  before it calls the server, and that in turn requires
  `Scheduling.Auth.enabled?/0` — the exchange runs through the shared provider
  worker. So a test using this stub must configure **both** `Scheduling.Core`
  and `Scheduling.Auth`, or `fetch/0` returns `{:error, :not_configured}`
  without ever reaching here.
  """
  use GenServer

  @doc "Starts the stub under `Scheduling.Auth.ServiceToken`'s registered name."
  def start_link(reply),
    do: GenServer.start_link(__MODULE__, reply, name: Scheduling.Auth.ServiceToken)

  @impl GenServer
  def init(reply), do: {:ok, reply}

  @impl GenServer
  def handle_call(:fetch, _from, reply), do: {:reply, reply, reply}

  @impl GenServer
  def handle_cast(:invalidate, reply), do: {:noreply, reply}
end
