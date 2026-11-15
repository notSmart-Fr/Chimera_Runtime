defmodule ChimeraRuntime.Runner.EngineContainmentPropertyTest do
  # async: false because the TaskSupervisor children count is global.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox.Plugin
  alias ChimeraRuntime.WasmFixtures

  @task_supervisor ChimeraRuntime.Runner.TaskSupervisor
  @timeout_ms 10_000

  setup do
    previous = Application.get_env(:chimera_runtime, :execution_recorder)
    Application.put_env(:chimera_runtime, :execution_recorder, fn _attrs -> {:ok, :recorded} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:chimera_runtime, :execution_recorder, previous),
        else: Application.delete_env(:chimera_runtime, :execution_recorder)
    end)

    :ok
  end

  defp rogue_case do
    one_of([
      # invalid bytes
      map(binary(min_length: 0, max_length: 64), fn bytes -> {"run", bytes} end),
      constant({"run", WasmFixtures.trap_unreachable()}),
      constant({"run", WasmFixtures.divide_by_zero()}),
      constant({"run", WasmFixtures.module_with_import()}),
      # missing export
      constant({"does_not_exist", WasmFixtures.no_results()}),
      constant({"missing", WasmFixtures.add()})
    ])
  end

  defp plugin(binary) do
    %Plugin{
      id: Ash.UUID.generate(),
      state: :active,
      wasm_binary: binary,
      timeout_ms: @timeout_ms,
      verification_used: false
    }
  end

  defp wait_until_empty(deadline) do
    case Task.Supervisor.children(@task_supervisor) do
      [] ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(5)
          wait_until_empty(deadline)
        end
    end
  end

  # Feature: poltergeist-sandbox, Property 2: failures are contained in the Engine
  # **Validates: Requirements 6.2, 6.4, 6.5, 6.6, 8.1, 8.5, 11.6, 11.7**
  property "rogue modules never affect the Caller, its mailbox or the TaskSupervisor" do
    check all({function, binary} <- rogue_case(), max_runs: 100) do
      caller = self()
      Process.flag(:trap_exit, true)

      result = Engine.run(plugin(binary), function, [])

      assert match?({:error, _}, result) or match?({:ok, _}, result)
      assert Process.alive?(caller)

      assert wait_until_empty(System.monotonic_time(:millisecond) + 100),
             "TaskSupervisor still has children: #{inspect(Task.Supervisor.children(@task_supervisor))}"

      assert {:messages, []} = Process.info(caller, :messages)
    end
  end
end
