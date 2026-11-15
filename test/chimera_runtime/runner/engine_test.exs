defmodule ChimeraRuntime.Runner.EngineTest do
  use ChimeraRuntime.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias ChimeraRuntime.Runner.{Engine, Worker}
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Execution
  alias ChimeraRuntime.WasmFixtures
  alias Wasmex.StoreOrCaller

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

  defp plugin!(binary, state \\ :active, attrs \\ %{}) do
    plugin =
      retry(fn ->
        Sandbox.create_plugin!(
          Map.merge(
            %{
              name: "engine-#{System.unique_integer([:positive])}",
              wasm_binary: binary,
              timeout_ms: 5_000
            },
            attrs
          )
        )
      end)

    case state do
      :draft -> plugin
      :compiling -> retry(fn -> Sandbox.compile_plugin!(plugin) end)
      :active -> plugin |> then(&retry(fn -> Sandbox.compile_plugin!(&1) end)) |> activate()
      :quarantined -> retry(fn -> Sandbox.quarantine_plugin!(plugin) end)
    end
  end

  defp activate(plugin), do: retry(fn -> Sandbox.activate_plugin!(plugin) end)

  defp executions(plugin) do
    retry(fn ->
      Execution |> Ash.Query.filter(plugin_id == ^plugin.id) |> Ash.read!()
    end)
  end

  describe "run results" do
    test "valid add module returns the known value" do
      plugin = plugin!(WasmFixtures.add())
      assert {:ok, [5]} = Engine.run(plugin, "add", [2, 3])
      assert [%{status: :success, run_mode: :standard}] = executions(plugin)
    end

    test "missing export" do
      plugin = plugin!(WasmFixtures.add())
      assert {:error, {:missing_export, "nope"}} = Engine.run(plugin, "nope", [])
      assert [%{status: :error}] = executions(plugin)
    end

    test "trap" do
      plugin = plugin!(WasmFixtures.trap_unreachable())
      assert {:error, {:trap, _}} = Engine.run(plugin, "run", [])
      assert [%{status: :error}] = executions(plugin)
    end

    test "unsatisfied import" do
      plugin = plugin!(WasmFixtures.module_with_import())
      assert {:error, {:unsatisfied_import, _}} = Engine.run(plugin, "run", [])
      assert [%{status: :error}] = executions(plugin)
    end

    test "fuel exhaustion records one :timeout Execution" do
      plugin = plugin!(WasmFixtures.infinite_loop())
      assert {:error, {:fuel_exhausted, _}} = Engine.run(plugin, "run", [])
      assert [%{status: :timeout, error_reason: reason}] = executions(plugin)
      assert is_binary(reason) and reason != ""
    end
  end

  describe "Worker.build_store/0" do
    test "yields finite fuel no greater than the configured budget" do
      budget =
        :chimera_runtime
        |> Application.fetch_env!(Engine)
        |> Keyword.fetch!(:fuel_budget)

      assert {:ok, store} = Worker.build_store()
      assert {:ok, fuel} = StoreOrCaller.get_fuel(store)
      assert is_integer(fuel) and fuel > 0 and fuel <= budget
    end
  end

  describe "shutdown race" do
    test "a reply that arrives during shutdown is honored" do
      assert {:finished, {:ok, [1]}} = Engine.settle({:ok, {:ok, [1]}})
      assert {:ok, [1]} = Engine.outcome_to_result(Engine.settle({:ok, {:ok, [1]}}))
      assert nil == Engine.settle(nil)
      assert {:crashed, :boom} = Engine.settle({:exit, :boom})
    end
  end

  describe "persistence failure" do
    setup do
      on_exit(fn -> Application.delete_env(:chimera_runtime, :execution_recorder) end)
    end

    test "logs once and returns the result unchanged" do
      plugin = plugin!(WasmFixtures.add())
      Application.put_env(:chimera_runtime, :execution_recorder, fn _ -> {:error, :disk_full} end)

      log =
        capture_log(fn ->
          assert {:ok, [7]} = Engine.run(plugin, "add", [3, 4])
        end)

      assert length(String.split(log, "failed to persist execution")) - 1 == 1
      assert executions(plugin) == []
    end

    test "a raising recorder is also contained" do
      plugin = plugin!(WasmFixtures.add())
      Application.put_env(:chimera_runtime, :execution_recorder, fn _ -> raise "boom" end)

      log = capture_log(fn -> assert {:ok, [3]} = Engine.run(plugin, "add", [1, 2]) end)
      assert length(String.split(log, "failed to persist execution")) - 1 == 1
    end
  end

  describe "verification flows" do
    test "first run succeeds, second returns :verification_already_used" do
      plugin = plugin!(WasmFixtures.add(), :compiling)

      assert {:ok, [3]} = Engine.run(plugin, "add", [1, 2], run_mode: :verification)
      assert [%{run_mode: :verification, status: :success}] = executions(plugin)

      reloaded = retry(fn -> Sandbox.get_plugin!(plugin.id) end)
      assert reloaded.verification_used
      assert reloaded.state == :compiling

      assert {:error, :verification_already_used} =
               Engine.run(reloaded, "add", [1, 2], run_mode: :verification)

      assert length(executions(plugin)) == 1

      # activate still succeeds afterward
      assert %{state: :active} = activate(reloaded)
    end

    test ":standard on :compiling returns :plugin_not_active" do
      plugin = plugin!(WasmFixtures.add(), :compiling)
      assert {:error, :plugin_not_active} = Engine.run(plugin, "add", [1, 2])
      assert executions(plugin) == []
    end

    for state <- [:draft, :active, :quarantined] do
      test ":verification on #{state} returns :plugin_not_active" do
        plugin = plugin!(WasmFixtures.add(), unquote(state))

        assert {:error, :plugin_not_active} =
                 Engine.run(plugin, "add", [1, 2], run_mode: :verification)

        assert executions(plugin) == []
      end
    end
  end

  describe "smoke checks" do
    test "Task.Supervisor is registered" do
      assert is_pid(Process.whereis(ChimeraRuntime.Runner.TaskSupervisor))
    end

    test ":ash_domains contains Sandbox and no Audit domain" do
      domains = Application.fetch_env!(:chimera_runtime, :ash_domains)
      assert ChimeraRuntime.Sandbox in domains
      refute Code.ensure_loaded?(ChimeraRuntime.Audit)
    end

    test "tables exist" do
      for table <- ~w(plugins executions executions_versions) do
        assert %{rows: [[^table]]} =
                 retry(fn ->
                   Ecto.Adapters.SQL.query!(
                     ChimeraRuntime.Repo,
                     "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                     [table]
                   )
                 end)
      end
    end
  end
end
