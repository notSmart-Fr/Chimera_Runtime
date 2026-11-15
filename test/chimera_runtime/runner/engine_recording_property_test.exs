defmodule ChimeraRuntime.Runner.EngineRecordingPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Execution
  alias ChimeraRuntime.WasmFixtures

  # Feature: poltergeist-sandbox, Property 4: Executions are recorded exactly when a Worker started
  # **Validates: Requirements 9.1, 9.8, 11.8, 11.9**

  @timeout_ms 5_000

  # {kind, expected_delta}
  defp scenario do
    one_of([
      # Worker starts
      tuple({constant(:valid), integer(-1000..1000), integer(-1000..1000)}),
      tuple({constant(:rogue_trap), constant(nil), constant(nil)}),
      tuple({constant(:rogue_div), constant(nil), constant(nil)}),
      tuple({constant(:rogue_import), constant(nil), constant(nil)}),
      tuple({constant(:missing_export), constant(nil), constant(nil)}),
      tuple({constant(:invalid_wasm), constant(nil), constant(nil)}),
      tuple({constant(:verification), integer(-1000..1000), integer(-1000..1000)}),
      # Fails before a Worker starts
      tuple({constant(:draft), constant(nil), constant(nil)}),
      tuple({constant(:compiling), constant(nil), constant(nil)}),
      tuple({constant(:quarantined), constant(nil), constant(nil)}),
      tuple({constant(:nil_binary), constant(nil), constant(nil)}),
      tuple({constant(:bad_function_name), constant(nil), constant(nil)}),
      tuple({constant(:bad_args), constant(nil), constant(nil)}),
      tuple({constant(:bad_timeout), constant(nil), constant(nil)})
    ])
  end

  defp retry(fun, attempts \\ 20) do
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

  defp create_plugin!(binary, target_state) do
    plugin =
      retry(fn ->
        Sandbox.create_plugin!(%{
          name: "rec-#{System.unique_integer([:positive])}",
          wasm_binary: binary,
          timeout_ms: @timeout_ms
        })
      end)

    advance(plugin, target_state)
  end

  defp advance(plugin, :draft), do: plugin

  defp advance(plugin, :compiling), do: retry(fn -> Sandbox.compile_plugin!(plugin) end)

  defp advance(plugin, :active) do
    plugin |> advance(:compiling) |> then(&retry(fn -> Sandbox.activate_plugin!(&1) end))
  end

  defp advance(plugin, :quarantined),
    do: retry(fn -> Sandbox.quarantine_plugin!(plugin) end)

  defp count(plugin) do
    retry(fn ->
      Execution |> Ash.Query.filter(plugin_id == ^plugin.id) |> Ash.count!()
    end)
  end

  # Returns {plugin, call args for Engine.run, expected delta}
  defp build({:valid, a, b}) do
    {create_plugin!(WasmFixtures.add(), :active), ["add", [a, b], []], 1}
  end

  defp build({:rogue_trap, _, _}),
    do: {create_plugin!(WasmFixtures.trap_unreachable(), :active), ["run", [], []], 1}

  defp build({:rogue_div, _, _}),
    do: {create_plugin!(WasmFixtures.divide_by_zero(), :active), ["run", [], []], 1}

  defp build({:rogue_import, _, _}),
    do: {create_plugin!(WasmFixtures.module_with_import(), :active), ["run", [], []], 1}

  defp build({:missing_export, _, _}),
    do: {create_plugin!(WasmFixtures.add(), :active), ["nope", [], []], 1}

  defp build({:invalid_wasm, _, _}),
    do: {create_plugin!(<<1, 2, 3, 4, 5>>, :active), ["run", [], []], 1}

  defp build({:verification, a, b}) do
    {create_plugin!(WasmFixtures.add(), :compiling), ["add", [a, b], [run_mode: :verification]],
     1}
  end

  defp build({state, _, _}) when state in [:draft, :compiling, :quarantined],
    do: {create_plugin!(WasmFixtures.add(), state), ["add", [1, 2], []], 0}

  defp build({:nil_binary, _, _}) do
    plugin = create_plugin!(WasmFixtures.add(), :active)
    {%{plugin | wasm_binary: nil}, ["add", [1, 2], []], 0}
  end

  defp build({:bad_function_name, _, _}),
    do: {create_plugin!(WasmFixtures.add(), :active), ["", [1, 2], []], 0}

  defp build({:bad_args, _, _}),
    do: {create_plugin!(WasmFixtures.add(), :active), ["add", :not_a_list, []], 0}

  defp build({:bad_timeout, _, _}) do
    plugin = create_plugin!(WasmFixtures.add(), :active)
    {%{plugin | timeout_ms: 0}, ["add", [1, 2], []], 0}
  end

  property "Executions are recorded exactly when a Worker started" do
    check all(spec <- scenario(), max_runs: 100) do
      {plugin, [fun, args, opts], expected_delta} = build(spec)

      before_count = count(plugin)
      result = Engine.run(plugin, fun, args, opts)
      after_count = count(plugin)

      assert after_count - before_count == expected_delta,
             "spec=#{inspect(spec)} result=#{inspect(result)} before=#{before_count} after=#{after_count}"

      if expected_delta == 0 do
        assert match?({:error, _}, result)
      end
    end
  end
end
