defmodule ChimeraRuntime.Sandbox.Plugin.Run do
  @moduledoc """
  Implementation of the generic Plugin action `:run` (MCP tool `run_plugin`).

  Order: fresh read of the Plugin, `mcp_max_timeout_ms` check, `RunGuard.check/0`,
  union unwrapping, then `Engine.run/4` in `:standard` mode. Total: every
  failure becomes `{:error, message}` where the message names only a failure
  category (at most 300 characters, no module names or stack traces).
  """
  use Ash.Resource.Actions.Implementation

  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.RunGuard
  alias ChimeraRuntime.Sandbox

  @default_mcp_max_timeout_ms 30_000
  @max_message 300

  @impl true
  def run(input, _opts, _context) do
    do_run(input)
  rescue
    _ -> {:error, to_error("error")}
  catch
    _, _ -> {:error, to_error("error")}
  end

  # AshAi renders Ash.Error.Action.InvalidArgument with its message (no field,
  # no path), while a bare string becomes a generic "unexpected error" text.
  defp to_error(category) do
    Ash.Error.Action.InvalidArgument.exception(message: category)
  end

  defp do_run(input) do
    id = Ash.ActionInput.get_argument(input, :id)
    fname = Ash.ActionInput.get_argument(input, :function_name)
    args = input |> Ash.ActionInput.get_argument(:args) |> unwrap_args()

    with {:ok, plugin} <- fetch_plugin(id),
         :ok <- check_timeout(plugin),
         :ok <- check_capacity() do
      execute(plugin, fname, args)
    end
  end

  defp fetch_plugin(id) do
    case Sandbox.get_plugin(id, not_found_error?: false) do
      {:ok, %{} = plugin} -> {:ok, plugin}
      {:ok, nil} -> {:error, to_error("not_found")}
      _ -> {:error, to_error("not_found")}
    end
  end

  defp check_timeout(%{timeout_ms: timeout_ms}) do
    if is_integer(timeout_ms) and timeout_ms > mcp_max_timeout_ms(),
      do: {:error, to_error("timeout_too_long_for_mcp")},
      else: :ok
  end

  defp check_capacity do
    case RunGuard.check() do
      :ok -> :ok
      {:error, :busy} -> {:error, to_error("busy")}
    end
  end

  defp execute(plugin, fname, args) do
    t0 = System.monotonic_time()
    result = Engine.run(plugin, fname, args, run_mode: :standard)
    wall_time_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)

    case result do
      {:ok, output} ->
        {:ok, %{"status" => "success", "output" => output, "wall_time_us" => wall_time_us}}

      {:error, reason} ->
        {:error, to_error(category(reason))}
    end
  end

  @doc false
  def unwrap_args(args) when is_list(args), do: Enum.map(args, &unwrap/1)
  def unwrap_args(_), do: []

  defp unwrap(%Ash.Union{value: value}), do: value
  defp unwrap(value), do: value

  @doc false
  # Maps an Engine error reason to a category string. Never includes details.
  def category(reason) do
    reason |> do_category() |> String.slice(0, @max_message)
  end

  defp do_category(:timeout), do: "timeout"
  defp do_category({:fuel_exhausted, _}), do: "timeout"
  defp do_category({:invalid_input, _}), do: "invalid_input"
  defp do_category(:invalid_timeout), do: "invalid_input"
  defp do_category(:plugin_not_active), do: "not_active"
  defp do_category(:missing_binary), do: "not_active"
  defp do_category({:compile_error, _}), do: "compile_error"
  defp do_category(:compile_error), do: "compile_error"
  defp do_category({:trap, _}), do: "trap"
  defp do_category(:trap), do: "trap"
  defp do_category(_), do: "error"

  defp mcp_max_timeout_ms do
    :chimera_runtime
    |> Application.get_env(:mcp, [])
    |> Keyword.get(:mcp_max_timeout_ms, @default_mcp_max_timeout_ms)
  end
end
