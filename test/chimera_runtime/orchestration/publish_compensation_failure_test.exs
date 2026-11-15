defmodule ChimeraRuntime.Orchestration.PublishCompensationFailureTest do
  use ChimeraRuntime.DataCase, async: false

  import ExUnit.CaptureLog

  alias ChimeraRuntime.Orchestration.PublishPluginReactor
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  @key ChimeraRuntime.Orchestration

  setup do
    original = Application.get_env(:chimera_runtime, @key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:chimera_runtime, @key)
        value -> Application.put_env(:chimera_runtime, @key, value)
      end
    end)

    put_config(verification_runner: fn _plugin, _fname, _args, _opts -> {:error, :boom} end)
    :ok
  end

  defp put_config(overrides) do
    current = Application.get_env(:chimera_runtime, @key, [])
    Application.put_env(:chimera_runtime, @key, Keyword.merge(current, overrides))
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

  defp draft_plugin! do
    retry(fn ->
      Sandbox.create_plugin!(%{
        name: "comp-#{System.unique_integer([:positive])}",
        wasm_binary: WasmFixtures.add(),
        timeout_ms: 5_000
      })
    end)
  end

  defp state_of(plugin), do: Sandbox.get_plugin!(plugin.id).state

  test "a failing quarantine leaves the plugin :compiling and reports compensation {:failed, reason}" do
    put_config(quarantine_fun: fn _plugin -> {:error, :quarantine_broken} end)
    plugin = draft_plugin!()

    log =
      capture_log([level: :error], fn ->
        send(self(), {:result, PublishPluginReactor.publish(plugin.id, "add", [1, 2])})
      end)

    assert_received {:result, result}

    assert {:error,
            %{
              stage: :verify,
              reason: :boom,
              plugin_state: :compiling,
              compensation: {:failed, _reason}
            }} = result

    assert state_of(plugin) == :compiling

    occurrences =
      log |> String.split("publish saga compensation failed") |> length() |> Kernel.-(1)

    assert occurrences == 1
    assert log =~ plugin.id
  end

  test "a raising quarantine_fun is contained and reported as a failed compensation" do
    put_config(quarantine_fun: fn _plugin -> raise "kaboom" end)
    plugin = draft_plugin!()

    capture_log([level: :error], fn ->
      send(self(), {:result, PublishPluginReactor.publish(plugin.id, "add", [1, 2])})
    end)

    assert_received {:result, {:error, %{compensation: {:failed, _}, plugin_state: :compiling}}}
  end

  test "transient 'database is locked' errors are retried, then reported as failed" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    put_config(
      quarantine_fun: fn _plugin ->
        Agent.update(counter, &(&1 + 1))
        {:error, %RuntimeError{message: "database is locked"}}
      end
    )

    plugin = draft_plugin!()

    capture_log([level: :error], fn ->
      send(self(), {:result, PublishPluginReactor.publish(plugin.id, "add", [1, 2])})
    end)

    assert_received {:result, {:error, %{compensation: {:failed, _}, plugin_state: :compiling}}}

    calls = Agent.get(counter, & &1)
    assert calls > 1
    assert calls <= 6
  end

  test "a transient error followed by success ends :quarantined" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    put_config(
      quarantine_fun: fn plugin ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> {:error, %RuntimeError{message: "database is locked"}}
          _ -> Sandbox.quarantine_plugin(plugin)
        end
      end
    )

    plugin = draft_plugin!()

    assert {:error, %{stage: :verify, plugin_state: :quarantined, compensation: :quarantined}} =
             PublishPluginReactor.publish(plugin.id, "add", [1, 2])

    assert state_of(plugin) == :quarantined
  end
end
