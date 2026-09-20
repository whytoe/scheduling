defmodule Scheduling.ConfigFilesTest do
  @moduledoc """
  The configuration files have to be readable by the Elixir this repository
  ships.

  Nothing else checks `config/dev.exs`. CI sets `MIX_ENV=test` at the workflow
  level and the image builds `MIX_ENV=prod`, so both skip the file entirely;
  `config/runtime.exs` is loaded for every environment and is therefore already
  exercised by every test run. That left the one file only developers read, on
  machines whose Elixir is newer than the pinned one — and `sc-lsg` was a
  `~r"..."E` sitting there breaking `mix phx.server`, `iex -S mix` and
  `mix test` without `MIX_ENV` set, on the toolchain the Dockerfile names.

  Two assertions, because one of them is not enough on its own:

    * **Loading** catches anything a config file does that the *running* Elixir
      rejects. In CI that is the pinned toolchain, which is the gate that
      matters. On a developer's newer Elixir it passes — a file that loads
      there really does load there — so it cannot be the whole check.
    * **Sigil modifiers** are checked against the set the pinned Elixir accepts
      rather than against the running one, so the failure reproduces on any
      machine. That is the half that would have caught `sc-lsg` locally.
  """
  use ExUnit.Case, async: true

  @config_dir Path.expand("../config", __DIR__)

  # `mix` reads config/config.exs, which ends in `import_config
  # "#{config_env()}.exs"`. Reading it once per environment therefore covers
  # every per-environment file. runtime.exs is deliberately absent: Mix loads
  # it for all environments including test, so it is already covered, and
  # reading it here would demand DATABASE_URL and friends.
  @envs [:dev, :test, :prod]

  # Regex modifiers Elixir accepted before 1.19.3, which is where `E`
  # (`:export`) arrived. The Dockerfile pins 1.18.5 and `.github/workflows/ci.yml`
  # reads that pin, so a modifier outside this set compiles on the machine that
  # wrote it and raises Regex.CompileError on the one that ships.
  #
  # Hardcoded rather than derived: there is no way to ask the running Elixir
  # what an older one would have accepted, and that is exactly the question.
  @modifiers_before_1_19_3 ~c"fimrsuUx"

  defp config_files do
    Path.wildcard(Path.join(@config_dir, "*.exs"))
  end

  test "every environment's configuration loads on the Elixir running this suite" do
    for env <- @envs do
      path = Path.join(@config_dir, "config.exs")

      assert is_list(Config.Reader.read!(path, env: env)),
             "config/config.exs did not read as a keyword list for MIX_ENV=#{env}"
    end
  end

  test "no config file uses a regex modifier the pinned Elixir does not have" do
    files = config_files()
    assert files != [], "expected to find config files under #{@config_dir}"

    for path <- files, {modifiers, line} <- regex_modifiers(path) do
      unknown = modifiers -- @modifiers_before_1_19_3

      assert unknown == [],
             """
             #{Path.relative_to(path, File.cwd!())}:#{line} uses the regex \
             modifier#{if length(unknown) > 1, do: "s", else: ""} \
             #{inspect(List.to_string(unknown))}, which Elixir 1.18.5 — the \
             version the Dockerfile pins — does not accept.

             Every mix task in that environment raises Regex.CompileError \
             while reading its own configuration. Drop the modifier, or move \
             the pin and this list together.
             """
    end
  end

  # The sigil AST is `{:sigil_r, meta, [{:<<>>, _, _}, modifiers]}` where
  # `modifiers` is a charlist. Walking it beats matching `~r` in the source
  # text, which would have to get regex-inside-regex quoting right.
  defp regex_modifiers(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:sigil_r, meta, [_source, modifiers]} = node, acc ->
        {node, [{modifiers, Keyword.get(meta, :line)} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
