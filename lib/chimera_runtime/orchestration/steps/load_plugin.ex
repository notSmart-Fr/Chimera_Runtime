defmodule ChimeraRuntime.Orchestration.Steps.LoadPlugin do
  @moduledoc """
  Preflight step of the publish saga. Reads the Plugin and rejects anything that
  cannot be published. Failures are `StageError{stage: :preflight}`.
  """

  use Reactor.Step

  alias ChimeraRuntime.Orchestration.StageError
  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox

  @impl true
  def run(%{plugin_id: plugin_id, function_name: function_name, args: args}, _context, _options) do
    with {:ok, plugin} <- read(plugin_id),
         {:ok, _mode} <-
           Engine.validate_input(plugin, function_name, args, run_mode: :verification),
         :ok <- check_state(plugin),
         :ok <- check_binary(plugin),
         :ok <- check_unused(plugin) do
      {:ok, plugin}
    else
      {:error, reason} -> {:error, %StageError{stage: :preflight, reason: reason}}
    end
  rescue
    e -> {:error, %StageError{stage: :preflight, reason: {:unexpected, Exception.message(e)}}}
  catch
    kind, value ->
      {:error, %StageError{stage: :preflight, reason: {:unexpected, {kind, inspect(value)}}}}
  end

  defp read(plugin_id) do
    case Sandbox.get_plugin(plugin_id, not_found_error?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, plugin} -> {:ok, plugin}
      {:error, error} -> {:error, classify_read_error(error)}
    end
  end

  defp classify_read_error(%{errors: errors}) when is_list(errors) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
      do: :not_found,
      else: {:read_failed, Exception.message(%Ash.Error.Unknown{errors: errors})}
  end

  defp classify_read_error(error), do: {:read_failed, inspect(error, limit: 20)}

  defp check_state(%{state: :draft}), do: :ok
  defp check_state(%{state: state}), do: {:error, {:invalid_state, state}}

  defp check_binary(%{wasm_binary: binary}) when is_binary(binary) and byte_size(binary) > 0,
    do: :ok

  defp check_binary(_), do: {:error, :missing_binary}

  defp check_unused(%{verification_used: true}), do: {:error, :verification_already_used}
  defp check_unused(_), do: :ok
end
