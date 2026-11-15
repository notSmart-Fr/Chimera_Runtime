defmodule ChimeraRuntime.Sandbox.Types.WasmNumberTest do
  use ExUnit.Case, async: true

  alias ChimeraRuntime.Sandbox.Types.WasmNumber

  defmodule SpikeResource do
    use Ash.Resource, domain: nil

    actions do
      action :run, :map do
        argument :args, {:array, ChimeraRuntime.Sandbox.Types.WasmNumber},
          allow_nil?: false,
          default: [],
          constraints: [min_length: 0, max_length: 64]

        run fn _input, _ctx -> {:ok, %{}} end
      end
    end
  end

  defp unwrap(%Ash.Union{value: value}), do: value

  defp cast(value) do
    {:ok, constraints} = Ash.Type.init(WasmNumber, [])
    Ash.Type.cast_input(WasmNumber, value, constraints)
  end

  describe "cast_input/2" do
    test "5 stays an integer" do
      assert {:ok, v} = cast(5)
      assert unwrap(v) === 5
    end

    test "5.0 stays a float" do
      assert {:ok, v} = cast(5.0)
      assert unwrap(v) === 5.0
    end

    test "5.5 stays a float" do
      assert {:ok, v} = cast(5.5)
      assert unwrap(v) === 5.5
    end
  end

  test "an array argument casts mixed numbers through the action input" do
    input =
      Ash.ActionInput.for_action(SpikeResource, :run, %{args: [5, 5.0, 5.5]},
        domain: ChimeraRuntime.Sandbox
      )

    assert input.valid?
    assert Enum.map(input.arguments.args, &unwrap/1) === [5, 5.0, 5.5]
  end

  test "ash_ai tool schema for an array of WasmNumber is valid" do
    action = Ash.Resource.Info.action(SpikeResource, :run)
    schema = AshAi.Tool.Schema.for_action(nil, SpikeResource, action)

    json = schema |> Jason.encode!() |> Jason.decode!()
    args = get_in(json, ["properties", "input", "properties", "args"])

    assert %{"type" => "array", "items" => %{"anyOf" => members}} = args
    assert Enum.sort(Enum.map(members, & &1["type"])) == ["integer", "number"]
  end
end
