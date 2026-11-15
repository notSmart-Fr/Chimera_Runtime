defmodule ChimeraRuntime.Sandbox.PluginValidationPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Plugin

  # Feature: poltergeist-sandbox, Property 12: Plugin field validation
  # **Validates: Requirements 2.1, 2.4, 2.5, 2.7, 2.8**

  @max_timeout 600_000

  defp name_of_length(len), do: String.duplicate("a", len)

  defp clear_plugins, do: Ecto.Adapters.SQL.query!(Repo, "DELETE FROM plugins", [])

  defp timeout_gen do
    one_of([
      integer(1..@max_timeout),
      member_of([1, @max_timeout]),
      integer(-1_000..0),
      integer((@max_timeout + 1)..(@max_timeout + 1_000_000)),
      member_of([0, @max_timeout + 1])
    ])
  end

  defp name_len_gen do
    one_of([integer(1..255), member_of([1, 255, 256]), integer(256..600)])
  end

  defp snapshot(plugin),
    do: Map.take(plugin, [:id, :name, :timeout_ms, :source_code, :updated_at])

  property "create accepts iff 1 <= timeout_ms <= 600_000" do
    check all(timeout <- timeout_gen(), max_runs: 100) do
      clear_plugins()
      result = Sandbox.create_plugin(%{name: "p", timeout_ms: timeout})

      if timeout >= 1 and timeout <= @max_timeout do
        assert {:ok, plugin} = result
        assert plugin.timeout_ms == timeout
      else
        assert {:error, _} = result
        assert Ash.read!(Plugin) == []
      end
    end
  end

  property "create accepts iff name length is 1..255" do
    check all(len <- name_len_gen(), max_runs: 100) do
      clear_plugins()
      result = Sandbox.create_plugin(%{name: name_of_length(len)})

      if len >= 1 and len <= 255 do
        assert {:ok, plugin} = result
        assert String.length(plugin.name) == len
      else
        assert {:error, _} = result
        assert Ash.read!(Plugin) == []
      end
    end
  end

  property "empty name is rejected" do
    check all(_ <- constant(nil), max_runs: 100) do
      clear_plugins()
      assert {:error, _} = Sandbox.create_plugin(%{name: ""})
      assert {:error, _} = Sandbox.create_plugin(%{})
    end
  end

  property "rejected update leaves the stored record unchanged" do
    check all(
            timeout <- timeout_gen(),
            len <- name_len_gen(),
            max_runs: 100
          ) do
      clear_plugins()
      plugin = Sandbox.create_plugin!(%{name: "original", timeout_ms: 500})
      before = snapshot(plugin)

      result =
        plugin
        |> Ash.Changeset.for_update(:update, %{name: name_of_length(len), timeout_ms: timeout})
        |> Ash.update()

      valid? = timeout in 1..@max_timeout and len in 1..255

      if valid? do
        assert {:ok, updated} = result
        assert updated.timeout_ms == timeout
        assert String.length(updated.name) == len
      else
        assert {:error, _} = result
        stored = Sandbox.get_plugin!(plugin.id)
        assert snapshot(stored) == before
      end
    end
  end
end
