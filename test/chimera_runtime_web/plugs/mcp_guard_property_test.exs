# Feature: observability-control-room, Property 11: MCP_Guard decision
defmodule ChimeraRuntimeWeb.Plugs.McpGuardPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ChimeraRuntimeWeb.Plugs.McpGuard

  @allowed_origins ["http://localhost:4000", "http://127.0.0.1:4000"]
  @token "a-configured-token-of-at-least-32-bytes!"

  defp ip_gen do
    one_of([
      constant({127, 0, 0, 1}),
      constant({0, 0, 0, 0, 0, 0, 0, 1}),
      tuple({integer(1..126), integer(0..255), integer(0..255), integer(0..255)}),
      tuple({integer(128..255), integer(0..255), integer(0..255), integer(0..255)}),
      constant({0xFE80, 0, 0, 0, 0, 0, 0, 2}),
      constant({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    ])
  end

  defp origin_gen do
    one_of([
      constant(nil),
      member_of(@allowed_origins),
      string(:alphanumeric, min_length: 1, max_length: 20)
      |> map(&("http://" <> &1 <> ".example"))
    ])
  end

  defp input_gen do
    gen all(
          env <- member_of([:dev, :test, :prod]),
          remote_ip <- ip_gen(),
          allow_loopback? <- boolean(),
          configured <-
            one_of([
              constant(nil),
              constant(""),
              constant(@token),
              string(:ascii, min_length: 1, max_length: 40)
            ]),
          supplied <-
            one_of([
              constant(nil),
              constant(""),
              constant(@token),
              string(:ascii, min_length: 1, max_length: 40),
              constant(:same)
            ]),
          origin <- origin_gen()
        ) do
      supplied = if supplied == :same, do: configured, else: supplied

      %{
        env: env,
        remote_ip: remote_ip,
        allow_loopback?: allow_loopback?,
        configured_token: configured,
        supplied_token: supplied,
        origin: origin,
        allowed_origins: @allowed_origins
      }
    end
  end

  # Independent oracle: evaluates the decision order top to bottom.
  defp oracle(i) do
    origin_bad = i.origin != nil and i.origin not in i.allowed_origins

    loopback_ip =
      i.remote_ip == {127, 0, 0, 1} or i.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}

    admitted = i.env != :prod and i.allow_loopback? and loopback_ip
    token_set = is_binary(i.configured_token) and byte_size(i.configured_token) > 0

    token_ok =
      token_set and is_binary(i.supplied_token) and byte_size(i.supplied_token) > 0 and
        i.supplied_token == i.configured_token

    cond do
      origin_bad -> {:deny, 403}
      admitted -> :allow
      not token_set -> {:deny, 503}
      token_ok -> :allow
      true -> {:deny, 401}
    end
  end

  # **Validates: Requirements 15.2, 15.3, 15.4, 15.5, 15.6, 15.8, 15.9, 15.13**
  property "decide/1 matches the ordered oracle and returns one of four outcomes" do
    check all(input <- input_gen(), max_runs: 100) do
      decision = McpGuard.decide(input)

      assert decision in [:allow, {:deny, 401}, {:deny, 403}, {:deny, 503}]
      assert decision == oracle(input)
    end
  end

  # **Validates: Requirements 15.4, 15.8, 15.13**
  property "allow only when Origin passes and loopback is admitted or the token matches" do
    check all(input <- input_gen(), max_runs: 100) do
      if McpGuard.decide(input) == :allow do
        origin_ok = input.origin == nil or input.origin in input.allowed_origins

        loopback_ok =
          input.env != :prod and input.allow_loopback? and
            input.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

        token_ok =
          is_binary(input.configured_token) and input.configured_token != "" and
            input.supplied_token == input.configured_token

        assert origin_ok
        assert loopback_ok or token_ok
      end
    end
  end
end
