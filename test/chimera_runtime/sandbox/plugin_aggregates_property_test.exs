defmodule ChimeraRuntime.Sandbox.PluginAggregatesPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.{Execution, Plugin}

  # Feature: poltergeist-sandbox, Property 9: failure_rate is bounded and exact
  # **Validates: Requirements 5.1, 5.3, 5.4, 5.7, 5.8, 11.10**

  defp execution_spec do
    gen all(
          status <- member_of([:success, :timeout, :error]),
          run_mode <- member_of([:standard, :verification]),
          duration <- integer(0..10_000)
        ) do
      %{status: status, run_mode: run_mode, duration_ms: duration}
    end
  end

  defp create_execution!(plugin, %{status: status} = spec) do
    reason = if status == :success, do: nil, else: "failure"

    Ash.create!(
      Execution,
      Map.merge(spec, %{plugin_id: plugin.id, error_reason: reason, input_json: %{}}),
      action: :create
    )
  end

  property "failure_rate is bounded and exact" do
    check all(
            specs <- list_of(execution_spec(), min_length: 0, max_length: 50),
            max_runs: 100
          ) do
      plugin =
        Sandbox.create_plugin!(%{name: "plugin-#{System.unique_integer([:positive])}"})

      Enum.each(specs, &create_execution!(plugin, &1))

      loaded = Ash.load!(plugin, [:total_runs, :failure_rate])

      total = length(specs)
      failed = Enum.count(specs, &(&1.status in [:timeout, :error]))

      assert loaded.total_runs == total
      assert is_float(loaded.failure_rate)
      assert loaded.failure_rate >= 0.0 and loaded.failure_rate <= 1.0

      if total == 0 do
        assert loaded.failure_rate == 0.0
      else
        assert_in_delta loaded.failure_rate, failed / total, 1.0e-9
      end

      # Reload from the store to make sure the result does not depend on the struct.
      reloaded = Plugin |> Ash.get!(plugin.id) |> Ash.load!([:total_runs, :failure_rate])
      assert reloaded.total_runs == total
      assert_in_delta reloaded.failure_rate, loaded.failure_rate, 1.0e-12
    end
  end
end
