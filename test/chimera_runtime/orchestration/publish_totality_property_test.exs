defmodule ChimeraRuntime.Orchestration.PublishTotalityPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Orchestration.PublishPluginReactor

  @stages [:lock, :preflight, :compile, :verify, :promote]
  @plugin_states [:draft, :compiling, :active, :quarantined, :unknown]

  defp id_gen do
    StreamData.one_of([
      StreamData.term(),
      StreamData.string(:printable),
      StreamData.repeatedly(&Ecto.UUID.generate/0),
      StreamData.repeatedly(fn -> Ecto.UUID.generate() <> "x" end),
      StreamData.constant(nil)
    ])
  end

  defp name_gen do
    StreamData.one_of([
      StreamData.term(),
      StreamData.string(:printable),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
    ])
  end

  defp args_gen do
    StreamData.one_of([
      StreamData.term(),
      StreamData.list_of(StreamData.term(), max_length: 5)
    ])
  end

  defp compensation?(:not_needed), do: true
  defp compensation?(:quarantined), do: true
  defp compensation?({:failed, _}), do: true
  defp compensation?(_), do: false

  # Feature: observability-control-room, Property 14: publish/3 is total
  # **Validates: Requirements 13.2, 13.4**
  property "publish/3 returns exactly one well-formed tuple for any three terms" do
    check all(
            plugin_id <- id_gen(),
            function_name <- name_gen(),
            args <- args_gen(),
            max_runs: 100
          ) do
      result =
        try do
          {:returned, PublishPluginReactor.publish(plugin_id, function_name, args)}
        catch
          kind, value -> {:escaped, kind, value}
        end

      case result do
        {:returned, {:ok, %{plugin: _, verification: %{output: _}}}} ->
          :ok

        {:returned, {:error, %{stage: stage, reason: _, plugin_state: state, compensation: comp}}} ->
          assert stage in @stages
          assert state in @plugin_states
          assert compensation?(comp)

        other ->
          flunk("publish/3 was not total: #{inspect(other, limit: 20)}")
      end
    end
  end
end
