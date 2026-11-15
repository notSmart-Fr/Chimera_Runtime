defmodule ChimeraRuntime.Orchestration.PublishOutcomePropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Orchestration.PublishPluginReactor
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  setup do
    previous = Application.fetch_env(:chimera_runtime, ChimeraRuntime.Orchestration)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:chimera_runtime, ChimeraRuntime.Orchestration, value)
        :error -> Application.delete_env(:chimera_runtime, ChimeraRuntime.Orchestration)
      end
    end)

    :ok
  end

  defp outcome do
    StreamData.one_of([
      StreamData.map(StreamData.term(), &{:ok, &1}),
      StreamData.constant({:error, :timeout}),
      StreamData.map(StreamData.positive_integer(), &{:error, {:fuel_exhausted, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:trap, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:compile_error, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:unsatisfied_import, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:missing_export, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:worker_exit, &1}}),
      StreamData.map(StreamData.string(:printable), &{:error, {:runtime_failure, &1}}),
      StreamData.member_of([
        {:error, :verification_already_used},
        {:error, :verification_marker_failed},
        {:error, :plugin_not_active},
        {:error, :missing_binary},
        {:error, :invalid_timeout}
      ])
    ])
  end

  # Feature: observability-control-room, Property 13: Saga outcome invariants
  # **Validates: Requirements 10.8, 10.10, 11.7, 12.2, 12.4, 13.1, 13.2, 13.7, 13.8**
  property "saga outcomes satisfy the success and failure invariants" do
    check all(result <- outcome(), max_runs: 50, max_shrinking_steps: 0) do
      put_runner(fn _plugin, _fun, _args, opts ->
        send(self(), {:runner_opts, opts})
        result
      end)

      plugin = draft_plugin()

      case PublishPluginReactor.publish(plugin.id, "run", []) do
        {:ok, %{plugin: published, verification: %{output: output}}} ->
          assert {:ok, ^output} = result
          assert published.state == :active
          assert reload(plugin).state == :active
          assert_received {:runner_opts, opts}
          assert opts[:run_mode] == :verification

        {:error, %{stage: stage, reason: reason, plugin_state: state, compensation: comp}} ->
          assert {:error, injected} = result
          assert stage == :verify
          assert reason == injected
          assert state == :quarantined
          assert comp == :quarantined
          assert reload(plugin).state == :quarantined
      end
    end
  end

  defp put_runner(fun) do
    Application.put_env(:chimera_runtime, ChimeraRuntime.Orchestration, verification_runner: fun)
  end

  defp draft_plugin do
    name = "plugin-#{System.unique_integer([:positive])}"

    with_retry(fn ->
      Sandbox.create_plugin!(%{name: name, wasm_binary: WasmFixtures.add(), timeout_ms: 500})
    end)
  end

  defp reload(plugin), do: with_retry(fn -> Sandbox.get_plugin!(plugin.id) end)

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
