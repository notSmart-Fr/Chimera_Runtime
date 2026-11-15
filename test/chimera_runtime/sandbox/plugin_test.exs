defmodule ChimeraRuntime.Sandbox.PluginTest do
  use ChimeraRuntime.DataCase

  alias ChimeraRuntime.Sandbox

  @wasm <<0, 97, 115, 109, 1, 0, 0, 0>>

  defp create!(attrs \\ %{}) do
    base = %{name: "plugin-#{System.unique_integer([:positive])}", wasm_binary: @wasm}
    Sandbox.create_plugin!(Map.merge(base, attrs))
  end

  defp in_state(:draft, attrs), do: create!(attrs)
  defp in_state(:compiling, attrs), do: attrs |> create!() |> Sandbox.compile_plugin!()
  defp in_state(:active, attrs), do: in_state(:compiling, attrs) |> Sandbox.activate_plugin!()

  defp in_state(:quarantined, attrs),
    do: attrs |> create!() |> Sandbox.quarantine_plugin!()

  describe "defaults" do
    test "new plugin is a draft with timeout 500 and verification_used false" do
      plugin = create!()
      assert plugin.state == :draft
      assert plugin.timeout_ms == 500
      assert plugin.verification_used == false
    end
  end

  describe "valid transitions" do
    test "draft -> compiling" do
      assert %{state: :compiling} = Sandbox.compile_plugin!(create!())
    end

    test "compiling -> active" do
      assert %{state: :active} = Sandbox.activate_plugin!(in_state(:compiling, %{}))
    end

    for from <- [:draft, :compiling, :active] do
      test "#{from} -> quarantined" do
        plugin = in_state(unquote(from), %{})
        assert %{state: :quarantined} = Sandbox.quarantine_plugin!(plugin)
      end
    end
  end

  describe "invalid transitions leave state unchanged" do
    @invalid [
      {:draft, :activate},
      {:compiling, :compile},
      {:active, :compile},
      {:active, :activate},
      {:quarantined, :compile},
      {:quarantined, :activate},
      {:quarantined, :quarantine}
    ]

    for {from, action} <- @invalid do
      test "#{action} from #{from} is rejected" do
        plugin = in_state(unquote(from), %{})

        result =
          case unquote(action) do
            :compile -> Sandbox.compile_plugin(plugin)
            :activate -> Sandbox.activate_plugin(plugin)
            :quarantine -> Sandbox.quarantine_plugin(plugin)
          end

        assert {:error, _} = result
        assert Sandbox.get_plugin!(plugin.id).state == unquote(from)
      end
    end
  end

  describe "activation requires a wasm binary" do
    test "nil binary is rejected and plugin stays compiling" do
      plugin = in_state(:compiling, %{wasm_binary: nil})
      assert {:error, error} = Sandbox.activate_plugin(plugin)
      assert Exception.message(error) =~ "wasm_binary"
      assert Sandbox.get_plugin!(plugin.id).state == :compiling
    end

    test "empty binary is rejected and plugin stays compiling" do
      plugin = in_state(:compiling, %{wasm_binary: <<>>})
      assert {:error, _} = Sandbox.activate_plugin(plugin)
      assert Sandbox.get_plugin!(plugin.id).state == :compiling
    end
  end

  describe "activate regardless of verification_used" do
    test "succeeds when verification_used is true" do
      plugin = in_state(:compiling, %{})
      assert %{verification_used: true} = Sandbox.mark_verification_used!(plugin)
      plugin = Sandbox.get_plugin!(plugin.id)
      assert %{state: :active, verification_used: true} = Sandbox.activate_plugin!(plugin)
    end

    test "succeeds when verification_used is false" do
      plugin = in_state(:compiling, %{})
      assert %{state: :active, verification_used: false} = Sandbox.activate_plugin!(plugin)
    end
  end

  describe "name" do
    test "must be unique" do
      create!(%{name: "dup"})
      assert {:error, error} = Sandbox.create_plugin(%{name: "dup", wasm_binary: @wasm})
      assert Exception.message(error) =~ "has already been taken"
    end
  end

  describe "size limits" do
    test "source_code at 1 MiB is accepted, above is rejected" do
      assert %{} = create!(%{source_code: String.duplicate("a", 1_048_576)})

      assert {:error, _} =
               Sandbox.create_plugin(%{
                 name: "big-src",
                 source_code: String.duplicate("a", 1_048_577)
               })
    end

    test "wasm_binary at 10 MiB is accepted, above is rejected" do
      assert %{} = create!(%{wasm_binary: :binary.copy(<<0>>, 10_485_760)})

      assert {:error, _} =
               Sandbox.create_plugin(%{
                 name: "big-wasm",
                 wasm_binary: :binary.copy(<<0>>, 10_485_761)
               })
    end

    test "timeout_ms bounds" do
      assert %{timeout_ms: 1} = create!(%{timeout_ms: 1})
      assert %{timeout_ms: 600_000} = create!(%{timeout_ms: 600_000})
      assert {:error, _} = Sandbox.create_plugin(%{name: "t0", timeout_ms: 0})
      assert {:error, _} = Sandbox.create_plugin(%{name: "t1", timeout_ms: 600_001})
    end
  end
end
