defmodule ChimeraRuntime.Runner.EngineExecutionShapePropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  # Feature: poltergeist-sandbox, Property 5: Recorded Executions are well-formed

  @max_duration 2_147_483_647
  @fuel_budget 1_000
  @timeout_ms 5_000

  setup do
    original = Application.fetch_env(:chimera_runtime, Engine)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:chimera_runtime, Engine, value)
        :error -> Application.delete_env(:chimera_runtime, Engine)
      end
    end)

    :ok
  end

  # {name, binary, function, args_generator, expected status}
  defp scenario do
    one_of([
      map(
        {integer(-1_000..1_000), integer(-1_000..1_000)},
        fn {a, b} -> {:add, WasmFixtures.add(), "add", [a, b], :success, :default} end
      ),
      constant({:no_results, WasmFixtures.no_results(), "run", [], :success, :default}),
      constant({:unreachable, WasmFixtures.trap_unreachable(), "run", [], :error, :default}),
      constant({:div_zero, WasmFixtures.divide_by_zero(), "run", [], :error, :default}),
      constant({:import, WasmFixtures.module_with_import(), "run", [], :error, :default}),
      constant({:missing_export, WasmFixtures.add(), "nope", [], :error, :default}),
      constant({:bad_args, WasmFixtures.add(), "add", [1], :error, :default}),
      map(binary(min_length: 1, max_length: 64), fn bin ->
        {:garbage, <<0xFF, 0xFE>> <> bin, "run", [], :error, :default}
      end),
      constant({:fuel, WasmFixtures.infinite_loop(), "run", [], :timeout, :small_fuel})
    ])
  end

  defp make_plugin(binary, mode) do
    {:ok, plugin} =
      with_retry(fn ->
        Sandbox.create_plugin(%{
          name: "p-#{System.unique_integer([:positive])}",
          wasm_binary: binary,
          timeout_ms: @timeout_ms
        })
      end)

    case mode do
      :standard ->
        {:ok, plugin} = with_retry(fn -> Sandbox.compile_plugin(plugin) end)
        {:ok, plugin} = with_retry(fn -> Sandbox.activate_plugin(plugin) end)
        plugin

      :verification ->
        {:ok, plugin} = with_retry(fn -> Sandbox.compile_plugin(plugin) end)
        plugin
    end
  end

  defp with_retry(fun, attempts \\ 20) do
    case fun.() do
      {:error, error} = result when attempts > 1 ->
        if String.contains?(inspect(error), "database is locked") or
             String.contains?(inspect(error), "busy") do
          Process.sleep(100)
          with_retry(fun, attempts - 1)
        else
          result
        end

      result ->
        result
    end
  end

  defp put_fuel(:small_fuel),
    do: Application.put_env(:chimera_runtime, Engine, fuel_budget: @fuel_budget)

  defp put_fuel(:default), do: Application.delete_env(:chimera_runtime, Engine)

  # Validates: Requirements 9.1, 9.2, 9.3, 9.7, 9.9, 9.10
  property "recorded Executions are well-formed", %{} do
    check all(
            {name, binary, function, args, expected_status, fuel} <- scenario(),
            run_mode <- member_of([:standard, :verification]),
            max_runs: 100
          ) do
      plugin = make_plugin(binary, run_mode)
      put_fuel(fuel)

      result = Engine.run(plugin, function, args, run_mode: run_mode)
      put_fuel(:default)

      assert match?({:ok, _}, result) == (expected_status == :success),
             "unexpected result #{inspect(result)} for #{name}"

      if expected_status == :timeout do
        assert {:error, {:fuel_exhausted, _}} = result
      end

      executions = Ash.load!(plugin, :executions, domain: Sandbox).executions
      assert [execution] = executions

      assert execution.plugin_id == plugin.id
      assert execution.status == expected_status
      assert execution.run_mode == run_mode
      assert is_integer(execution.duration_ms)
      assert execution.duration_ms in 0..@max_duration
      assert is_map(execution.input_json)
      assert execution.input_json["function"] == function

      case expected_status do
        :success ->
          assert execution.error_reason == nil

        _ ->
          assert is_binary(execution.error_reason)
          assert String.trim(execution.error_reason) != ""
          assert String.length(execution.error_reason) <= 1000
      end

      if expected_status == :timeout do
        assert execution.error_reason =~ "fuel"
      end
    end
  end
end
