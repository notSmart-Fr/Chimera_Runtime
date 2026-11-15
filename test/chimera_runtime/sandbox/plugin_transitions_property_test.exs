defmodule ChimeraRuntime.Sandbox.PluginTransitionsPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox

  # Feature: poltergeist-sandbox, Property 11: Invalid transitions are rejected and leave the Plugin unchanged
  # **Validates: Requirements 3.6, 3.7, 3.8**

  @paths %{
    draft: [],
    compiling: [:compile_plugin],
    active: [:compile_plugin, :activate_plugin],
    quarantined: [:quarantine_plugin]
  }

  @valid %{
    compile_plugin: [:draft],
    activate_plugin: [:compiling],
    quarantine_plugin: [:draft, :compiling, :active]
  }

  @invalid_pairs for state <- Map.keys(@paths),
                     action <- Map.keys(@valid),
                     state not in Map.fetch!(@valid, action),
                     do: {state, action}

  defp plugin_in_state(state, name, binary) do
    plugin = Sandbox.create_plugin!(%{name: name, wasm_binary: binary})

    Enum.reduce(Map.fetch!(@paths, state), plugin, fn action, acc ->
      apply(Sandbox, action, [acc]) |> unwrap()
    end)
  end

  defp unwrap({:ok, plugin}), do: plugin
  defp unwrap(%{} = plugin), do: plugin

  defp snapshot(plugin) do
    Map.take(plugin, [
      :id,
      :state,
      :name,
      :source_code,
      :wasm_binary,
      :timeout_ms,
      :verification_used,
      :inserted_at,
      :updated_at
    ])
  end

  property "invalid transitions are rejected and leave the Plugin unchanged" do
    check all(
            {state, action} <- member_of(@invalid_pairs),
            suffix <- positive_integer(),
            binary <- binary(min_length: 1, max_length: 32),
            max_runs: 100
          ) do
      name = "plugin-#{System.unique_integer([:positive])}-#{suffix}"
      plugin = plugin_in_state(state, name, binary)
      plugin = Sandbox.get_plugin!(plugin.id)
      assert plugin.state == state
      before = snapshot(plugin)

      assert {:error, error} = apply(Sandbox, action, [plugin])

      # Error identifies the current state and the attempted action (3.6).
      messages = Exception.message(error) |> String.downcase()
      assert messages =~ Atom.to_string(state)
      assert messages =~ action |> Atom.to_string() |> String.replace_suffix("_plugin", "")

      # Stored Plugin is unchanged (3.7, 3.8).
      stored = Sandbox.get_plugin!(plugin.id)
      assert snapshot(stored) == before
    end
  end
end
