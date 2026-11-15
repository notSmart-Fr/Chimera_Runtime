defmodule ChimeraRuntime.Runner.EngineInvalidBytesPropertyTest do
  use ChimeraRuntime.DataCase, async: false
  use ExUnitProperties

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox

  # Feature: poltergeist-sandbox, Property 1: Invalid Wasm bytes are rejected without harm
  # **Validates: Requirements 11.2, 11.3, 11.4, 8.2, 10.3**

  @magic <<0, "asm">>

  defp active_plugin(bytes) do
    plugin =
      Sandbox.create_plugin!(%{
        name: "plugin-#{System.unique_integer([:positive])}",
        wasm_binary: bytes,
        timeout_ms: 10_000
      })

    # Activation rejects an empty binary, so the state is set on the struct passed to the Engine.
    %{plugin | state: :active, wasm_binary: bytes}
  end

  defp assert_rejected(bytes) do
    caller = self()
    result = Engine.run(active_plugin(bytes), "run", [], [])

    assert {:error, _reason} = result
    assert Process.alive?(caller)
  end

  property "arbitrary bytes of 0..4096 are rejected" do
    check all(bytes <- binary(min_length: 0, max_length: 4096), max_runs: 100) do
      # A random blob that happens to be a valid module is practically impossible,
      # but the empty module is the one valid 8-byte input; it has no "run" export anyway.
      assert_rejected(bytes)
    end
  end

  property "magic header followed by 0..4096 random bytes is rejected" do
    check all(rest <- binary(min_length: 0, max_length: 4096), max_runs: 100) do
      assert_rejected(@magic <> rest)
    end
  end

  property "inputs whose first four bytes differ from the magic are rejected" do
    non_magic =
      one_of([
        binary(min_length: 0, max_length: 3),
        gen all(
              head <- binary(length: 4),
              head != @magic,
              rest <- binary(min_length: 0, max_length: 4092)
            ) do
          head <> rest
        end
      ])

    check all(bytes <- non_magic, max_runs: 100) do
      assert_rejected(bytes)
    end
  end
end
