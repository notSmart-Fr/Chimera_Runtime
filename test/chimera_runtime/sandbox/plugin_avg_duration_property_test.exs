defmodule ChimeraRuntime.Sandbox.PluginAvgDurationPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox

  # Feature: poltergeist-sandbox, Property 10: Average duration is the mean of non-nil durations
  # **Validates: Requirements 5.2, 5.5**
  #
  # Execution.duration_ms is `allow_nil? false`, so every stored Execution has a
  # non-nil duration; the mean is therefore taken over all Executions.

  defp new_plugin do
    Sandbox.create_plugin!(%{name: "plugin-#{System.unique_integer([:positive])}"})
  end

  defp execution_attrs(plugin, {status, duration}) do
    %{
      plugin_id: plugin.id,
      input_json: %{"function" => "f", "args" => []},
      duration_ms: duration,
      status: status,
      error_reason: if(status == :success, do: nil, else: "failed")
    }
  end

  defp avg(plugin), do: Ash.load!(plugin, :avg_duration_ms, domain: Sandbox).avg_duration_ms

  property "avg_duration_ms equals the arithmetic mean of execution durations" do
    run = tuple({member_of([:success, :timeout, :error]), integer(0..100_000)})

    check all(runs <- list_of(run, min_length: 1, max_length: 12), max_runs: 100) do
      plugin = new_plugin()
      Enum.each(runs, &Sandbox.create_execution!(execution_attrs(plugin, &1)))

      durations = Enum.map(runs, &elem(&1, 1))
      expected = Enum.sum(durations) / length(durations)

      actual = avg(plugin)
      assert is_number(actual)
      assert_in_delta actual, expected, 1.0e-6
    end
  end

  property "avg_duration_ms is nil for a Plugin with no executions" do
    check all(_ <- constant(:ok), max_runs: 100) do
      assert avg(new_plugin()) == nil
    end
  end
end
