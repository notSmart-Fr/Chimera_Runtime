defmodule ChimeraRuntimeWeb.Plugs.McpLimits do
  @moduledoc """
  Caps the `limit` argument of `list_plugins` tool calls at 100.

  The AshAi MCP router reads `conn.params`, so both `conn.params` and
  `conn.body_params` are rewritten. A batch arrives as `%{"_json" => list}`.
  `limit` is a top-level tool argument (`params.arguments.limit`).
  """

  @behaviour Plug

  @max_limit 100
  @tool "list_plugins"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    %{
      conn
      | params: clamp_limit(conn.params),
        body_params: clamp_limit(conn.body_params)
    }
  end

  @doc """
  Pure. Accepts a single JSON-RPC request map or a `%{"_json" => list}` batch
  and returns it with every `list_plugins` `tools/call` limit capped at 100.
  A missing, non-integer, or oversized limit becomes 100.
  """
  @spec clamp_limit(term()) :: term()
  def clamp_limit(%{"_json" => list} = params) when is_list(list),
    do: %{params | "_json" => Enum.map(list, &clamp_request/1)}

  def clamp_limit(%{} = params) when not is_struct(params), do: clamp_request(params)
  def clamp_limit(other), do: other

  @doc """
  `tool_argument_transformer` form (external capture only).
  """
  @spec transform_arguments(term(), term(), map()) :: {:ok, map()}
  def transform_arguments(_tool, _context, %{} = arguments),
    do: {:ok, Map.put(arguments, "limit", cap(Map.get(arguments, "limit")))}

  defp clamp_request(
         %{"method" => "tools/call", "params" => %{"name" => @tool} = params} = request
       ) do
    arguments =
      case params["arguments"] do
        %{} = args -> args
        _ -> %{}
      end

    arguments = Map.put(arguments, "limit", cap(Map.get(arguments, "limit")))
    %{request | "params" => Map.put(params, "arguments", arguments)}
  end

  defp clamp_request(request), do: request

  defp cap(limit) when is_integer(limit), do: min(limit, @max_limit)
  defp cap(_), do: @max_limit
end
