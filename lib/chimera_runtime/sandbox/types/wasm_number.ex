defmodule ChimeraRuntime.Sandbox.Types.WasmNumber do
  @moduledoc """
  A WebAssembly numeric argument: an integer or a float.

  `integer` is listed before `float` so that `5` stays an integer (needed for
  Wasm `i32`/`i64` parameters) while `5.5` falls through to float.
  """
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        integer: [type: :integer],
        float: [type: :float]
      ]
    ]
end
