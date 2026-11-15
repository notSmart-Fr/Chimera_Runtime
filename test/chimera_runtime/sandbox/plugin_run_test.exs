defmodule ChimeraRuntime.Sandbox.PluginRunTest do
  use ChimeraRuntime.DataCase, async: false

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Plugin
  alias ChimeraRuntime.WasmFixtures

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

  defp plugin!(timeout_ms, activate? \\ true) do
    plugin =
      retry(fn ->
        Sandbox.create_plugin!(%{
          name: "run-#{System.unique_integer([:positive])}",
          wasm_binary: WasmFixtures.add(),
          timeout_ms: timeout_ms
        })
      end)

    if activate? do
      plugin = retry(fn -> Sandbox.compile_plugin!(plugin) end)
      retry(fn -> Sandbox.activate_plugin!(plugin) end)
    else
      plugin
    end
  end

  defp run(plugin, fname, args) do
    Plugin
    |> Ash.ActionInput.for_action(:run, %{id: plugin.id, function_name: fname, args: args})
    |> Ash.run_action()
  end

  test "runs add and returns structured result" do
    plugin = plugin!(5_000)

    assert {:ok, %{"status" => "success", "output" => [5], "wall_time_us" => us}} =
             run(plugin, "add", [2, 3])

    assert is_integer(us)
  end

  test "non-active plugin returns a category-only error" do
    plugin = plugin!(5_000, false)
    assert {:error, error} = run(plugin, "add", [2, 3])
    assert Exception.message(error) =~ "not_active"
  end

  test "timeout above mcp_max_timeout_ms is rejected" do
    plugin = plugin!(40_000)
    assert {:error, error} = run(plugin, "add", [2, 3])
    assert Exception.message(error) =~ "timeout_too_long_for_mcp"
  end

  test "more than 64 args is rejected by argument constraints" do
    plugin = plugin!(5_000)
    assert {:error, _} = run(plugin, "add", Enum.to_list(1..65))
  end
end
