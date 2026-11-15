defmodule ChimeraRuntime.Orchestration.PublishPluginReactorTest do
  use ChimeraRuntime.DataCase, async: false

  require Ash.Query

  alias ChimeraRuntime.Orchestration.PublishPluginReactor
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Execution
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

  defp draft!(binary, attrs \\ %{}) do
    retry(fn ->
      Sandbox.create_plugin!(
        Map.merge(
          %{
            name: "saga-#{System.unique_integer([:positive])}",
            wasm_binary: binary,
            timeout_ms: 5_000
          },
          attrs
        )
      )
    end)
  end

  defp reload(plugin), do: retry(fn -> Sandbox.get_plugin!(plugin.id) end)

  defp executions(plugin) do
    retry(fn -> Execution |> Ash.Query.filter(plugin_id == ^plugin.id) |> Ash.read!() end)
  end

  defp publish(plugin, fun, args), do: retry_publish(plugin.id, fun, args)

  defp retry_publish(id, fun, args), do: PublishPluginReactor.publish(id, fun, args)

  describe "happy path" do
    test "add ends :active with one verification Execution" do
      plugin = draft!(WasmFixtures.add())

      assert {:ok, %{plugin: %{state: :active}, verification: %{output: [5]}}} =
               publish(plugin, "add", [2, 3])

      assert %{state: :active} = reload(plugin)
      assert [%{run_mode: :verification, status: :success}] = executions(plugin)
    end
  end

  describe "failures after compile are quarantined with compensation" do
    for {name, fixture, fun} <- [
          {"trap_unreachable", :trap_unreachable, "run"},
          {"divide_by_zero", :divide_by_zero, "run"},
          {"module_with_import", :module_with_import, "run"}
        ] do
      test "#{name} ends :quarantined" do
        plugin = draft!(apply(WasmFixtures, unquote(fixture), []))

        assert {:error, %{stage: :verify, plugin_state: :quarantined, compensation: :quarantined}} =
                 publish(plugin, unquote(fun), [])

        assert %{state: :quarantined} = reload(plugin)
        assert [%{run_mode: :verification, status: :error}] = executions(plugin)
      end
    end

    test "missing export is quarantined" do
      plugin = draft!(WasmFixtures.add())

      assert {:error, %{stage: :verify, plugin_state: :quarantined, compensation: :quarantined}} =
               publish(plugin, "nope", [])
    end

    test "infinite_loop with small fuel ends :quarantined with a :timeout Execution" do
      original = Application.get_env(:chimera_runtime, ChimeraRuntime.Runner.Engine, [])

      on_exit(fn ->
        Application.put_env(:chimera_runtime, ChimeraRuntime.Runner.Engine, original)
      end)

      Application.put_env(
        :chimera_runtime,
        ChimeraRuntime.Runner.Engine,
        Keyword.put(original, :fuel_budget, 10_000)
      )

      plugin = draft!(WasmFixtures.infinite_loop())

      assert {:error,
              %{
                stage: :verify,
                reason: {:fuel_exhausted, _},
                plugin_state: :quarantined,
                compensation: :quarantined
              }} = publish(plugin, "run", [])

      assert %{state: :quarantined} = reload(plugin)
      assert [%{status: :timeout, run_mode: :verification}] = executions(plugin)
    end
  end

  describe "preflight rejections" do
    test "missing binary leaves the plugin :draft" do
      plugin = draft!(nil, %{source_code: "(module)"})

      assert {:error,
              %{
                stage: :preflight,
                reason: :missing_binary,
                plugin_state: :draft,
                compensation: :not_needed
              }} = publish(plugin, "run", [])

      assert %{state: :draft} = reload(plugin)
      assert [] = executions(plugin)
    end

    test "an :active plugin is returned unchanged" do
      plugin = draft!(WasmFixtures.add())
      assert {:ok, _} = publish(plugin, "add", [1, 2])
      before = reload(plugin)

      assert {:error,
              %{
                stage: :preflight,
                reason: {:invalid_state, :active},
                plugin_state: :active,
                compensation: :not_needed
              }} = publish(plugin, "add", [1, 2])

      assert reload(plugin) == before
      assert [_one] = executions(plugin)
    end

    test "a consumed one-shot returns :verification_already_used" do
      plugin = draft!(WasmFixtures.add())

      retry(fn ->
        Ash.Seed.update!(plugin, %{verification_used: true})
      end)

      assert {:error,
              %{
                stage: :preflight,
                reason: :verification_already_used,
                plugin_state: :draft,
                compensation: :not_needed
              }} = publish(plugin, "add", [1, 2])

      assert %{state: :draft} = reload(plugin)
      assert [] = executions(plugin)
    end

    test "invalid arguments are rejected before any change" do
      plugin = draft!(WasmFixtures.add())

      assert {:error, %{stage: :preflight, reason: {:invalid_input, :publish_arguments}}} =
               PublishPluginReactor.publish(plugin.id, "", [])

      assert %{state: :draft} = reload(plugin)
    end

    test "unknown id returns :not_found" do
      id = Ecto.UUID.generate()

      assert {:error,
              %{
                stage: :preflight,
                reason: :not_found,
                plugin_state: :unknown,
                compensation: :not_needed
              }} = PublishPluginReactor.publish(id, "add", [1, 2])
    end
  end

  describe "concurrent publish" do
    test "a held lock yields :lock / :publish_in_progress and changes nothing" do
      plugin = draft!(WasmFixtures.add())
      test_pid = self()

      holder =
        spawn_link(fn ->
          :global.trans(
            {{PublishPluginReactor, plugin.id}, self()},
            fn ->
              send(test_pid, :locked)

              receive do
                :release -> :ok
              end
            end,
            [node()],
            :infinity
          )
        end)

      assert_receive :locked, 5_000

      assert {:error,
              %{
                stage: :lock,
                reason: :publish_in_progress,
                plugin_state: :draft,
                compensation: :not_needed
              }} = publish(plugin, "add", [1, 2])

      send(holder, :release)
      assert %{state: :draft} = reload(plugin)

      # Once released the publish succeeds.
      assert {:ok, %{plugin: %{state: :active}}} = publish_eventually(plugin)
    end
  end

  defp publish_eventually(plugin, attempts \\ 40) do
    case publish(plugin, "add", [1, 2]) do
      {:error, %{stage: :lock}} when attempts > 0 ->
        Process.sleep(50)
        publish_eventually(plugin, attempts - 1)

      other ->
        other
    end
  end
end
