defmodule ChimeraRuntime.Sandbox.ExecutionDurationPropertyTest do
  use ChimeraRuntime.DataCase
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox

  # Feature: poltergeist-sandbox, Property 13: Execution duration range

  @max 2_147_483_647

  setup do
    {:ok, plugin} = Sandbox.create_plugin(%{name: "plugin-#{System.unique_integer([:positive])}"})
    %{plugin: plugin}
  end

  defp attrs(plugin, duration) do
    %{
      plugin_id: plugin.id,
      input_json: %{"function" => "f", "args" => []},
      duration_ms: duration,
      status: :success
    }
  end

  defp valid_duration do
    one_of([
      integer(0..@max),
      member_of([0, 1, @max - 1, @max])
    ])
  end

  defp invalid_duration do
    one_of([
      constant(nil),
      integer(-@max..-1),
      integer((@max + 1)..(@max * 4)),
      map(float(min: 0.01, max: 1000.0), &(&1 + 0.5)),
      map(string(:alphanumeric, min_length: 1, max_length: 10), &("x" <> &1)),
      member_of([:abc, [1], %{"a" => 1}, true])
    ])
  end

  defp has_duration_error?(error) do
    Enum.any?(error.errors, &(Map.get(&1, :field) == :duration_ms))
  end

  # Validates: Requirements 4.5
  property "durations within 0..2_147_483_647 are accepted on create and update",
           %{plugin: plugin} do
    {:ok, execution} = Sandbox.create_execution(attrs(plugin, 1))

    check all(d <- valid_duration(), d2 <- valid_duration(), max_runs: 100) do
      assert {:ok, created} = Sandbox.create_execution(attrs(plugin, d))
      assert created.duration_ms == d

      assert {:ok, updated} =
               Ash.update(execution, %{duration_ms: d2}, action: :update, domain: Sandbox)

      assert updated.duration_ms == d2
    end
  end

  # Validates: Requirements 4.5, 4.6
  property "invalid durations are rejected on create with a duration_ms error",
           %{plugin: plugin} do
    check all(d <- invalid_duration(), max_runs: 100) do
      before = length(Sandbox.list_executions!())

      assert {:error, error} = Sandbox.create_execution(attrs(plugin, d))
      assert has_duration_error?(error)
      assert length(Sandbox.list_executions!()) == before
    end
  end

  # Validates: Requirements 4.6
  property "invalid durations are rejected on update and leave the stored record unchanged",
           %{plugin: plugin} do
    {:ok, execution} = Sandbox.create_execution(attrs(plugin, 42))

    check all(d <- invalid_duration(), max_runs: 100) do
      assert {:error, error} =
               Ash.update(execution, %{duration_ms: d}, action: :update, domain: Sandbox)

      assert has_duration_error?(error)

      reloaded = Ash.get!(ChimeraRuntime.Sandbox.Execution, execution.id, domain: Sandbox)
      assert reloaded.duration_ms == 42
    end
  end

  # Validates: Requirements 4.5
  property "omitting duration_ms on create is rejected", %{plugin: plugin} do
    check all(_ <- constant(:ok), max_runs: 100) do
      assert {:error, error} =
               Sandbox.create_execution(Map.delete(attrs(plugin, 1), :duration_ms))

      assert has_duration_error?(error)
    end
  end
end
