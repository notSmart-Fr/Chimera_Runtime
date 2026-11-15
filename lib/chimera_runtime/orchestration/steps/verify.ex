defmodule ChimeraRuntime.Orchestration.Steps.Verify do
  @moduledoc """
  Runs one Gravedigger verification against a fresh read of the Plugin.
  Any raise, exit or throw becomes `StageError{stage: :verify}`.
  """

  use Reactor.Step

  alias ChimeraRuntime.Orchestration.StageError
  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox

  @impl true
  def run(%{plugin: %{id: id}, function_name: function_name, args: args}, _context, _options) do
    runner =
      :chimera_runtime
      |> Application.get_env(ChimeraRuntime.Orchestration, [])
      |> Keyword.get(:verification_runner, &Engine.run/4)

    with {:ok, fresh} <- read(id),
         {:ok, output} <- runner.(fresh, function_name, args, run_mode: :verification) do
      {:ok, %{output: output}}
    else
      {:error, reason} -> {:error, %StageError{stage: :verify, reason: reason}}
      other -> {:error, %StageError{stage: :verify, reason: {:unexpected_result, other}}}
    end
  rescue
    e -> {:error, %StageError{stage: :verify, reason: {:raised, Exception.message(e)}}}
  catch
    kind, value ->
      {:error, %StageError{stage: :verify, reason: {kind, inspect(value, limit: 20)}}}
  end

  defp read(id) do
    case Sandbox.get_plugin(id, not_found_error?: false) do
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end
end
