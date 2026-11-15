defmodule ChimeraRuntime.Runner.EngineDeadlinePropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  # The test config budget (100_000) runs out long before any deadline. This budget
  # outlasts the largest deadline (500 ms) so the BEAM deadline fires first, but stays
  # finite: Wasmex cannot interrupt a running NIF call, so an instance abandoned at the
  # deadline keeps spinning on a dirty scheduler until its fuel runs out (about 1.2 s
  # at ~1.25e9 fuel/s). An unbounded budget leaks one dirty scheduler per iteration
  # and starves the run after as many iterations as there are dirty CPU schedulers.
  @deadline_fuel 1_500_000_000

  setup do
    previous = Application.fetch_env(:chimera_runtime, Engine)
    current = Application.get_env(:chimera_runtime, Engine, [])

    Application.put_env(
      :chimera_runtime,
      Engine,
      Keyword.put(current, :fuel_budget, @deadline_fuel)
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:chimera_runtime, Engine, value)
        :error -> Application.delete_env(:chimera_runtime, Engine)
      end
    end)

    :ok
  end

  # Feature: poltergeist-sandbox, Property 3: Infinite loops hit the deadline and leave no spinning instance
  # **Validates: Requirements 7.1, 7.3, 7.4, 7.5, 7.12, 7.13, 11.5, 11.16**
  property "infinite loops hit the deadline and leave no spinning instance" do
    check all(timeout_ms <- StreamData.integer(10..500), max_runs: 20, max_shrinking_steps: 0) do
      looping = active_plugin(WasmFixtures.infinite_loop(), timeout_ms)
      valid = active_plugin(WasmFixtures.add(), 500)

      {elapsed_us, result} = :timer.tc(fn -> Engine.run(looping, "run", []) end)

      assert result == {:error, :timeout}
      assert div(elapsed_us, 1000) <= timeout_ms + 100

      {follow_us, follow} = :timer.tc(fn -> Engine.run(valid, "add", [2, 3]) end)

      assert {:ok, [5]} = follow
      assert div(follow_us, 1000) <= 500
    end
  end

  defp active_plugin(binary, timeout_ms) do
    name = "plugin-#{System.unique_integer([:positive])}"

    plugin =
      with_retry(fn ->
        Sandbox.create_plugin!(%{name: name, wasm_binary: binary, timeout_ms: timeout_ms})
      end)

    plugin = with_retry(fn -> Sandbox.compile_plugin!(plugin) end)
    with_retry(fn -> Sandbox.activate_plugin!(plugin) end)
  end

  defp with_retry(fun, attempts \\ 10) do
    fun.()
  rescue
    e ->
      if attempts > 1 and Exception.message(e) =~ "database is locked" do
        Process.sleep(100)
        with_retry(fun, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end
end
