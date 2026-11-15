defmodule ChimeraRuntime.Runner.EngineGatePropertyTest do
  # async: false because the TaskSupervisor children count and SQLite are shared.
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Execution

  @task_supervisor ChimeraRuntime.Runner.TaskSupervisor
  @states [:draft, :compiling, :active, :quarantined]

  # Feature: poltergeist-sandbox, Property 7: Gate decision matches the truth table
  # **Validates: Requirements 8.6, 8.7, 8.8, 8.9, 8.10**

  # Independent oracle: the truth table written out as a flat list of rows.
  # {run_mode, state, has_binary?, verification_used} => result
  defp oracle(run_mode, state, binary?, used?) do
    rows =
      for mode <- [:standard, :verification],
          st <- @states,
          b <- [true, false],
          u <- [true, false] do
        result =
          cond do
            mode == :standard and st != :active -> {:error, :plugin_not_active}
            mode == :standard and not b -> {:error, :missing_binary}
            mode == :standard -> :ok
            st != :compiling -> {:error, :plugin_not_active}
            u -> {:error, :verification_already_used}
            not b -> {:error, :missing_binary}
            true -> :ok
          end

        {{mode, st, b, u}, result}
      end

    rows |> Map.new() |> Map.fetch!({run_mode, state, binary?, used?})
  end

  defp combo do
    tuple({
      member_of([:standard, :verification]),
      member_of(@states),
      boolean(),
      boolean()
    })
  end

  property "gate/1 matches the truth table for every combination" do
    check all({mode, state, binary?, used?} <- combo(), max_runs: 100) do
      assert Engine.gate({mode, state, binary?, used?}) == oracle(mode, state, binary?, used?)
    end
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

  # Builds a persisted Plugin in `state`. Active requires a binary (activate validates it).
  defp build_plugin(state, binary?, used?) do
    attrs = %{name: "gate-#{System.unique_integer([:positive])}"}

    attrs =
      if binary?, do: Map.put(attrs, :wasm_binary, ChimeraRuntime.WasmFixtures.add()), else: attrs

    plugin = Sandbox.create_plugin!(attrs)

    plugin =
      case state do
        :draft -> plugin
        :compiling -> Sandbox.compile_plugin!(plugin)
        :active -> plugin |> Sandbox.compile_plugin!() |> Sandbox.activate_plugin!()
        :quarantined -> Sandbox.quarantine_plugin!(plugin)
      end

    if used?, do: Sandbox.mark_verification_used!(plugin), else: plugin
  end

  defp executions, do: Ash.count!(Execution)
  defp children, do: length(Task.Supervisor.children(@task_supervisor))

  property "gate errors start no Worker, record no Execution and leave the Plugin unchanged" do
    check all(
            {mode, state, binary?, used?} <- combo(),
            # An active Plugin without a binary cannot be created through the actions.
            not (state == :active and not binary?),
            max_runs: 100
          ) do
      retry(fn ->
        plugin = build_plugin(state, binary?, used?)
        persisted = Sandbox.get_plugin!(plugin.id)

        expected =
          oracle(
            mode,
            persisted.state,
            is_binary(persisted.wasm_binary),
            persisted.verification_used
          )

        if expected != :ok do
          children_before = children()
          executions_before = executions()

          assert {:error, reason} = Engine.run(persisted, "add", [1, 2], run_mode: mode)
          assert {:error, reason} == expected

          assert children() == children_before
          assert executions() == executions_before
          assert Sandbox.get_plugin!(plugin.id) == persisted
        end
      end)
    end
  end
end
