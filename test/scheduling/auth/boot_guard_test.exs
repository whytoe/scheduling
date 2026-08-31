defmodule Scheduling.Auth.BootGuardTest do
  # async: false — these mutate the OS environment, which is process-global.
  use ExUnit.Case, async: false

  alias Scheduling.Auth

  @vars ["OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  defp put_all(value \\ "set"), do: Enum.each(@vars, &System.put_env(&1, value))

  describe "configured_from_env?/0" do
    test "true when all three are present" do
      put_all()
      assert Auth.configured_from_env?()
    end

    test "false when none are set" do
      refute Auth.configured_from_env?()
    end

    for var <- @vars do
      test "false when #{var} alone is missing" do
        put_all()
        System.delete_env(unquote(var))
        refute Auth.configured_from_env?()
      end

      test "false when #{var} is blank" do
        put_all()
        System.put_env(unquote(var), "   ")
        refute Auth.configured_from_env?()
      end
    end
  end

  describe "independence from the application environment" do
    # The bug this guards against: `config/runtime.exs` calls this while it is
    # still assembling `config :scheduling, Scheduling.Auth`, so the
    # application environment does not yet hold those values. A version that
    # consulted `Application.get_env/3` reported "not configured" on every
    # :prod boot regardless of the environment, and no amount of correct
    # deployment configuration could satisfy it.
    setup do
      saved = Application.get_env(:scheduling, Auth)
      on_exit(fn -> Application.put_env(:scheduling, Auth, saved) end)
      :ok
    end

    test "true from the environment alone, with app config empty" do
      Application.put_env(:scheduling, Auth, [])
      put_all()

      assert Auth.configured_from_env?(),
             "must read System.get_env/1, not the application environment"
    end

    test "false from the environment alone, with app config fully populated" do
      Application.put_env(:scheduling, Auth,
        issuer: "https://idp.example",
        client_id: "scheduling",
        client_secret: "shhh"
      )

      refute Auth.configured_from_env?(),
             "app config must not stand in for a missing environment"
    end
  end
end
