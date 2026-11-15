defmodule ChimeraRuntime.Sandbox.ExecutionValidationPropertyTest do
  use ChimeraRuntime.DataCase
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox

  # Feature: poltergeist-sandbox, Property 8: Execution error_reason agrees with status

  setup do
    {:ok, plugin} = Sandbox.create_plugin(%{name: "plugin-#{System.unique_integer([:positive])}"})
    %{plugin: plugin}
  end

  defp version_count, do: Sandbox.list_execution_versions!() |> length()
  defp execution_count, do: Sandbox.list_executions!() |> length()

  defp attrs(plugin, status, reason) do
    %{
      plugin_id: plugin.id,
      input_json: %{"function" => "f", "args" => []},
      duration_ms: 1,
      status: status,
      error_reason: reason
    }
  end

  defp nonblank_reason do
    gen all(
          prefix <- string(:alphanumeric, min_length: 1, max_length: 40),
          pad <- member_of(["", " ", "\n"])
        ) do
      pad <> prefix <> pad
    end
  end

  defp blank_reason do
    gen(all(s <- string([?\s, ?\t, ?\n], max_length: 10), do: s))
  end

  defp valid_case do
    one_of([
      constant({:success, nil}),
      tuple({member_of([:timeout, :error]), nonblank_reason()})
    ])
  end

  defp invalid_case do
    one_of([
      tuple({constant(:success), one_of([nonblank_reason(), blank_reason()])}),
      tuple({member_of([:timeout, :error]), one_of([constant(nil), blank_reason()])})
    ])
  end

  # Validates: Requirements 4.11, 4.12
  property "valid status/error_reason pairs are accepted on create", %{plugin: plugin} do
    check all({status, reason} <- valid_case(), max_runs: 100) do
      before_versions = version_count()

      assert {:ok, execution} = Sandbox.create_execution(attrs(plugin, status, reason))
      assert execution.status == status
      assert execution.error_reason == reason
      assert version_count() == before_versions + 1
    end
  end

  # Validates: Requirements 4.11, 4.12, 4.13
  property "mismatched status/error_reason pairs are rejected on create with no version row",
           %{plugin: plugin} do
    check all({status, reason} <- invalid_case(), max_runs: 100) do
      before_versions = version_count()
      before_executions = execution_count()

      assert {:error, error} = Sandbox.create_execution(attrs(plugin, status, reason))
      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :error_reason))

      assert version_count() == before_versions
      assert execution_count() == before_executions
    end
  end

  # Validates: Requirements 4.11, 4.12, 4.13
  property "updates that break agreement are rejected, leave the row and versions unchanged",
           %{plugin: plugin} do
    {:ok, execution} = Sandbox.create_execution(attrs(plugin, :success, nil))

    check all({status, reason} <- invalid_case(), max_runs: 100) do
      before_versions = version_count()

      assert {:error, _} =
               Ash.update(execution, %{status: status, error_reason: reason},
                 action: :update,
                 domain: Sandbox
               )

      assert version_count() == before_versions
      reloaded = Ash.get!(ChimeraRuntime.Sandbox.Execution, execution.id, domain: Sandbox)
      assert reloaded.status == :success
      assert reloaded.error_reason == nil
    end
  end
end
