defmodule ChimeraRuntime.Runner.EngineTotalityPropertyTest do
  # async: false because the TaskSupervisor children count is global.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine

  @task_supervisor ChimeraRuntime.Runner.TaskSupervisor

  # Feature: poltergeist-sandbox, Property 6: Engine is total
  # **Validates: Requirements 10.1, 10.3, 10.4, 10.5, 10.6, 7.2**
  property "Engine.run/4 returns exactly one ok/error result for any terms" do
    check all(
            plugin <- StreamData.term(),
            function_name <- StreamData.term(),
            args <- StreamData.term(),
            opts <- StreamData.term(),
            max_runs: 100
          ) do
      before = Task.Supervisor.children(@task_supervisor)

      result =
        try do
          {:returned, Engine.run(plugin, function_name, args, opts)}
        catch
          kind, value -> {:raised, kind, value}
        end

      assert {:returned, value} = result
      assert valid_result?(value), "unexpected result: #{inspect(value)}"

      # Invalid input starts no Worker and leaves no residue.
      assert Task.Supervisor.children(@task_supervisor) == before

      refute_received _any
    end
  end

  defp valid_result?({:ok, list}) when is_list(list), do: true
  defp valid_result?({:error, reason}) when is_atom(reason), do: true

  defp valid_result?({:error, reason}) when is_tuple(reason) and tuple_size(reason) > 0,
    do: is_atom(elem(reason, 0))

  defp valid_result?(_), do: false
end
