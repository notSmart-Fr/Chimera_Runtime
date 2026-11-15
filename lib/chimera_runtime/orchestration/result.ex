defmodule ChimeraRuntime.Orchestration.Result do
  @moduledoc """
  Pure helpers that shape publish saga results.

  Unwraps `Reactor.Error.*` wrappers to the first `StageError`, derives the
  compensation outcome, and builds the error map.
  """

  alias ChimeraRuntime.Orchestration.StageError
  alias Reactor.Error.Invalid.UndoRetriesExceededError
  alias Reactor.Error.Invalid.UndoStepError

  @type stage :: :lock | :preflight | :compile | :verify | :promote
  @type compensation :: :not_needed | :quarantined | {:failed, term()}
  @type plugin_state :: :draft | :compiling | :active | :quarantined | :unknown

  @type parts :: %{stage: stage(), reason: term(), compensation: compensation()}

  @inspect_limit 500

  @doc """
  Derives `%{stage, reason, compensation}` from a Reactor error (or error list).

  An error without a `StageError` becomes stage `:verify` with
  `{:unexpected, trimmed_inspect}`.
  """
  @spec from_reactor_error(term()) :: parts()
  def from_reactor_error(error) do
    flat = flatten(error)

    {stage, reason} =
      case Enum.find(flat, &match?(%StageError{}, &1)) do
        %StageError{stage: stage, reason: reason} -> {stage, reason}
        nil -> {:verify, {:unexpected, trim_inspect(error)}}
      end

    %{stage: stage, reason: reason, compensation: compensation(stage, flat)}
  end

  @doc "Builds the saga error tuple from error parts and the observed Plugin state."
  @spec error(parts(), plugin_state()) :: {:error, map()}
  def error(%{stage: stage, reason: reason, compensation: compensation}, plugin_state) do
    {:error,
     %{stage: stage, reason: reason, plugin_state: plugin_state, compensation: compensation}}
  end

  @doc "Builds the error tuple for a rejected stage with no compensation needed."
  @spec error(stage(), term(), plugin_state()) :: {:error, map()}
  def error(stage, reason, plugin_state) do
    error(%{stage: stage, reason: reason, compensation: :not_needed}, plugin_state)
  end

  defp compensation(stage, _flat) when stage in [:lock, :preflight, :compile], do: :not_needed

  defp compensation(_stage, flat) do
    case Enum.find(flat, &undo_error?/1) do
      nil -> :quarantined
      %UndoStepError{error: reason} -> {:failed, reason}
      %UndoRetriesExceededError{} = e -> {:failed, {:undo_retries_exceeded, e.retry_count}}
    end
  end

  defp undo_error?(%UndoStepError{}), do: true
  defp undo_error?(%UndoRetriesExceededError{}), do: true
  defp undo_error?(_), do: false

  # Walks wrapper errors (Invalid, Unknown, Aggregate-like) depth-first into a
  # flat list that keeps wrappers' leaves in order.
  defp flatten(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)

  defp flatten(%{errors: errors} = wrapper) when is_list(errors) do
    [wrapper | flatten(errors)]
  end

  # RunStepError, UndoStepError and CompensateStepError carry the cause in `:error`.
  defp flatten(%{error: inner} = wrapper) when is_struct(wrapper) and is_struct(inner) do
    [wrapper | flatten(inner)]
  end

  defp flatten(other), do: [other]

  defp trim_inspect(term) do
    inspect(term, limit: 20, printable_limit: @inspect_limit)
    |> String.slice(0, @inspect_limit)
  end
end
