defmodule ChimeraRuntime.Sandbox.ExecutionTest do
  use ChimeraRuntime.DataCase

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.{Execution, Plugin}

  setup do
    {:ok, plugin} = Sandbox.create_plugin(%{name: "plugin-#{System.unique_integer([:positive])}"})
    %{plugin: plugin}
  end

  defp version_count, do: Sandbox.list_execution_versions!() |> length()
  defp execution_count, do: Sandbox.list_executions!() |> length()

  defp attrs(plugin, overrides \\ %{}) do
    Map.merge(
      %{
        plugin_id: plugin.id,
        input_json: %{"function" => "f", "args" => []},
        output_json: %{"result" => 1},
        duration_ms: 5,
        status: :success
      },
      overrides
    )
  end

  describe "domain registration" do
    # Validates: Requirements 1.2 (adjusted)
    test "Sandbox domain includes Plugin, Execution and Execution.Version" do
      resources = Ash.Domain.Info.resources(Sandbox)

      assert Plugin in resources
      assert Execution in resources
      assert Execution.Version in resources
    end

    test "no Audit domain is defined" do
      refute Code.ensure_loaded?(ChimeraRuntime.Audit)
    end
  end

  describe "versioning" do
    # Validates: Requirements 4.15, 11.19
    test "one create produces exactly one version row", %{plugin: plugin} do
      before_versions = version_count()

      assert {:ok, execution} = Sandbox.create_execution(attrs(plugin))

      versions = Sandbox.list_execution_versions!()
      assert length(versions) == before_versions + 1
      assert Enum.count(versions, &(&1.version_source_id == execution.id)) == 1
    end
  end

  describe "create validation" do
    # Validates: Requirements 4.2
    test "nil output_json persists", %{plugin: plugin} do
      assert {:ok, execution} = Sandbox.create_execution(attrs(plugin, %{output_json: nil}))
      assert execution.output_json == nil

      reloaded = Ash.get!(Execution, execution.id, domain: Sandbox)
      assert reloaded.output_json == nil
    end

    # Validates: Requirements 4.4
    test "missing plugin reference is rejected with no version row", %{plugin: plugin} do
      before_versions = version_count()
      before_executions = execution_count()

      assert {:error, _} = Sandbox.create_execution(attrs(plugin, %{plugin_id: nil}))

      assert version_count() == before_versions
      assert execution_count() == before_executions
    end

    # Validates: Requirements 4.4
    test "nonexistent plugin reference is rejected with no version row", %{plugin: plugin} do
      before_versions = version_count()
      before_executions = execution_count()

      assert {:error, _} =
               Sandbox.create_execution(attrs(plugin, %{plugin_id: Ash.UUID.generate()}))

      assert version_count() == before_versions
      assert execution_count() == before_executions
    end

    # Validates: Requirements 4.8, 4.13
    test "invalid status is rejected with no version row", %{plugin: plugin} do
      before_versions = version_count()

      assert {:error, _} = Sandbox.create_execution(attrs(plugin, %{status: :bogus}))

      assert version_count() == before_versions
    end

    # Validates: Requirements 4.10, 4.13
    test "invalid run_mode is rejected with no version row", %{plugin: plugin} do
      before_versions = version_count()

      assert {:error, _} = Sandbox.create_execution(attrs(plugin, %{run_mode: :bogus}))

      assert version_count() == before_versions
    end
  end
end
