defmodule ChimeraRuntimeWeb.Plugs.McpBodySizePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ChimeraRuntimeWeb.Plugs.McpGuard

  @max 65_536

  # Feature: observability-control-room, Property 12: Body size decision
  # **Validates: Requirements 15.10**
  property "body_size_decision/1 returns :ok exactly when content-length <= 65536" do
    check all(
            len <-
              one_of([
                integer(0..(@max + 10)),
                integer(0..10_000_000),
                member_of([0, 1, @max - 1, @max, @max + 1])
              ]),
            has_body? <- boolean(),
            max_runs: 100
          ) do
      result = McpGuard.body_size_decision(%{content_length: len, has_body?: has_body?})

      if len <= @max do
        assert result == :ok
      else
        assert result == {:deny, 413}
      end
    end
  end

  # Feature: observability-control-room, Property 12: Body size decision
  # **Validates: Requirements 15.10**
  property "a request with a body and no content-length is denied with 413" do
    check all(
            length_key <- member_of([:absent, :nil_value]),
            max_runs: 100
          ) do
      input =
        case length_key do
          :absent -> %{has_body?: true}
          :nil_value -> %{content_length: nil, has_body?: true}
        end

      assert McpGuard.body_size_decision(input) == {:deny, 413}
    end
  end

  test "a request without a body and without content-length is allowed" do
    assert McpGuard.body_size_decision(%{content_length: nil, has_body?: false}) == :ok
  end
end
