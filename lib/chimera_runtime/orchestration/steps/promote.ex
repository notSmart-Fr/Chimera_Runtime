defmodule ChimeraRuntime.Orchestration.Steps.Promote do
  @moduledoc """
  Moves the verified Plugin to `:active` using a fresh read.
  Failures are `StageError{stage: :promote}`.
  """

  use Reactor.Step

  alias ChimeraRuntime.Orchestration.StageError
  alias ChimeraRuntime.Sandbox

  @impl true
  def run(%{plugin: %{id: id}}, _context, _options) do
    with {:ok, fresh} when not is_nil(fresh) <-
           Sandbox.get_plugin(id, not_found_error?: false),
         {:ok, active} <- Sandbox.activate_plugin(fresh) do
      {:ok, active}
    else
      {:ok, nil} -> {:error, %StageError{stage: :promote, reason: :not_found}}
      {:error, reason} -> {:error, %StageError{stage: :promote, reason: reason}}
    end
  rescue
    e -> {:error, %StageError{stage: :promote, reason: {:raised, Exception.message(e)}}}
  catch
    kind, value ->
      {:error, %StageError{stage: :promote, reason: {kind, inspect(value, limit: 20)}}}
  end
end
