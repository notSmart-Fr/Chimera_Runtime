defmodule ChimeraRuntime.Runner.EngineVerificationPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Execution
  alias ChimeraRuntime.WasmFixtures

  # Feature: poltergeist-sandbox, Property 14: Verification is one-shot and non-state-changing
  # **Validates: Requirements 8.11, 8.13, 3.10, 8.10**

  @timeout_ms 10_000
  @small_fuel 100_000

  setup do
    previous = Application.get_env(:chimera_runtime, Engine)
    Application.put_env(:chimera_runtime, Engine, fuel_budget: @small_fuel)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:chimera_runtime, Engine, previous),
        else: Application.delete_env(:chimera_runtime, Engine)
    end)

    :ok
  end

  defp outcome do
    one_of([
      tuple({constant(:success), integer(-1000..1000), integer(-1000..1000)}),
      tuple({constant(:trap), constant(0), constant(0)}),
      tuple({constant(:timeout), constant(0), constant(0)}),
      tuple({constant(:import_failure), constant(0), constant(0)})
    ])
  end

  defp retry(fun, attempts \\ 40) do
    fun.()
  rescue
    e ->
      if attempts > 0 and Exception.message(e) =~ "database is locked" do
        Process.sleep(50)
        retry(fun, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp fixture(:success, a, b), do: {WasmFixtures.add(), "add", [a, b]}
  defp fixture(:trap, _, _), do: {WasmFixtures.trap_unreachable(), "run", []}
  defp fixture(:timeout, _, _), do: {WasmFixtures.infinite_loop(), "run", []}
  defp fixture(:import_failure, _, _), do: {WasmFixtures.module_with_import(), "run", []}

  defp count(plugin) do
    retry(fn -> Execution |> Ash.Query.filter(plugin_id == ^plugin.id) |> Ash.count!() end)
  end

  property "verification is one-shot and non-state-changing for every outcome" do
    check all({kind, a, b} <- outcome(), max_runs: 100, max_shrinking_steps: 5) do
      {binary, fun, args} = fixture(kind, a, b)

      plugin =
        retry(fn ->
          Sandbox.create_plugin!(%{
            name: "ver-#{System.unique_integer([:positive])}",
            wasm_binary: binary,
            timeout_ms: @timeout_ms
          })
        end)

      plugin = retry(fn -> Sandbox.compile_plugin!(plugin) end)
      assert plugin.state == :compiling
      assert plugin.verification_used == false

      first = Engine.run(plugin, fun, args, run_mode: :verification)

      case kind do
        :success ->
          assert first == {:ok, [a + b]}

        :timeout ->
          assert match?({:error, {:fuel_exhausted, _}}, first) or first == {:error, :timeout}

        _ ->
          assert match?({:error, _}, first), "kind=#{kind} first=#{inspect(first)}"
      end

      reloaded = retry(fn -> Sandbox.get_plugin!(plugin.id) end)
      assert reloaded.verification_used == true
      assert reloaded.state == :compiling
      assert count(plugin) == 1

      # Second run with the fresh record (gate) and with the stale record (atomic filter).
      for candidate <- [reloaded, plugin] do
        assert Engine.run(candidate, fun, args, run_mode: :verification) ==
                 {:error, :verification_already_used}
      end

      assert count(plugin) == 1

      still = retry(fn -> Sandbox.get_plugin!(plugin.id) end)
      assert still.state == :compiling

      activated = retry(fn -> Sandbox.activate_plugin!(still) end)
      assert activated.state == :active
    end
  end
end
