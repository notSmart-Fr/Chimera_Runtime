defmodule ChimeraRuntimeWeb.Plugs.McpGuard do
  @moduledoc """
  Transport-level authorization for the MCP endpoint.

  Checks, in order: body size (413), then `decide/1` (Origin 403, admitted
  loopback, no configured token 503, bad or missing token 401).

  Loopback is decided from `conn.remote_ip` only. Forwarded headers are never read.
  The configured token is never logged.
  """

  @behaviour Plug

  import Plug.Conn

  @max_body_bytes 65_536
  @env Mix.env()

  @type decision :: :allow | {:deny, 401 | 403 | 503}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with :ok <- body_size_decision(body_input(conn)),
         :allow <- decide(decision_input(conn)) do
      conn
    else
      {:deny, status} -> deny(conn, status)
    end
  end

  @doc """
  Pure body size decision.

  Input: `%{content_length: non_neg_integer | nil, has_body?: boolean}`.
  Denies with 413 above 65536 bytes, or when a body is present without a length.
  """
  @spec body_size_decision(map()) :: :ok | {:deny, 413}
  def body_size_decision(%{content_length: len}) when is_integer(len) and len > @max_body_bytes,
    do: {:deny, 413}

  def body_size_decision(%{content_length: len}) when is_integer(len), do: :ok
  def body_size_decision(%{has_body?: true}), do: {:deny, 413}
  def body_size_decision(_), do: :ok

  @doc """
  Pure guard decision.

  Input: `%{env, remote_ip, allow_loopback?, configured_token, supplied_token,
  origin, allowed_origins}`. Loopback admission applies only in `:dev` and `:test`.
  """
  @spec decide(map()) :: decision()
  def decide(input) do
    cond do
      origin_denied?(input[:origin], input[:allowed_origins]) -> {:deny, 403}
      loopback_admitted?(input) -> :allow
      not configured?(input[:configured_token]) -> {:deny, 503}
      token_matches?(input[:configured_token], input[:supplied_token]) -> :allow
      true -> {:deny, 401}
    end
  end

  @doc "True for `127.0.0.1` and `::1` (also the IPv4-mapped form)."
  @spec loopback?(term()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 65_535, a, _}) when a in 0x7F00..0x7FFF, do: true
  def loopback?(_), do: false

  @doc """
  Runtime check of an Origin value against `config :chimera_runtime, :mcp, allowed_origins`.

  Passed to `AshAi.Mcp.Router` as `&McpGuard.origin_allowed?/1` (an external
  capture, which `forward` can escape) so the router's own Origin check uses
  the same list this guard reads at run time.
  """
  @spec origin_allowed?(term()) :: boolean()
  def origin_allowed?(origin) do
    allowed = Keyword.get(config(), :allowed_origins, [])
    not origin_denied?(origin, allowed)
  end

  defp origin_denied?(nil, _allowed), do: false
  defp origin_denied?(origin, allowed) when is_list(allowed), do: origin not in allowed
  defp origin_denied?(_origin, _allowed), do: true

  defp loopback_admitted?(input) do
    input[:env] in [:dev, :test] and input[:allow_loopback?] == true and
      loopback?(input[:remote_ip])
  end

  defp configured?(token), do: is_binary(token) and token != ""

  defp token_matches?(configured, supplied) when is_binary(supplied) and supplied != "",
    do: Plug.Crypto.secure_compare(configured, supplied)

  defp token_matches?(_configured, _supplied), do: false

  defp config, do: Application.get_env(:chimera_runtime, :mcp, [])

  defp decision_input(conn) do
    config = config()

    %{
      env: @env,
      remote_ip: conn.remote_ip,
      allow_loopback?: Keyword.get(config, :allow_loopback_without_token?, false),
      configured_token: Keyword.get(config, :token),
      supplied_token: bearer_token(conn),
      origin: conn |> get_req_header("origin") |> List.first(),
      allowed_origins: Keyword.get(config, :allowed_origins, [])
    }
  end

  defp body_input(conn) do
    length =
      case get_req_header(conn, "content-length") do
        [value | _] ->
          case Integer.parse(value) do
            {n, ""} when n >= 0 -> n
            _ -> nil
          end

        [] ->
          nil
      end

    chunked? = get_req_header(conn, "transfer-encoding") != []
    has_body? = chunked? or conn.method in ["POST", "PUT", "PATCH"]

    %{content_length: length, has_body?: has_body?}
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] -> if String.downcase(scheme) == "bearer", do: String.trim(token)
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp deny(conn, status) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message(status)}))
    |> halt()
  end

  defp message(401), do: "unauthorized"
  defp message(403), do: "forbidden"
  defp message(413), do: "payload too large"
  defp message(503), do: "mcp token not configured"
end
