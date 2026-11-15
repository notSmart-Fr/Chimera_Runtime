defmodule ChimeraRuntime.Orchestration.Steps.BeginCompile do
  @moduledoc """
  Moves the Plugin from `:draft` to `:compiling`. Its `undo/4` is the saga
  compensation: it re-reads the Plugin and quarantines it. Reactor stores an undo
  only after the step succeeded, so compensation runs only when a later step fails.
  """

  use Reactor.Step

  require Logger

  alias ChimeraRuntime.Orchestration.StageError
  alias ChimeraRuntime.Sandbox

  @impl true
  def run(%{plugin: plugin}, _context, _options) do
    case Sandbox.compile_plugin(plugin) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, %StageError{stage: :compile, reason: reason}}
    end
  rescue
    e -> {:error, %StageError{stage: :compile, reason: {:unexpected, Exception.message(e)}}}
  catch
    kind, value ->
      {:error, %StageError{stage: :compile, reason: {:unexpected, {kind, inspect(value)}}}}
  end

  @impl true
  def undo(compiled, _arguments, _context, _options) do
    id = plugin_id(compiled)

    case Sandbox.get_plugin(id, not_found_error?: false) do
      {:ok, %{state: :quarantined}} ->
        :ok

      {:ok, %{} = fresh} ->
        fresh |> quarantine() |> outcome(id)

      {:ok, nil} ->
        fail(id, :not_found)

      {:error, error} ->
        outcome({:error, error}, id)
    end
  rescue
    e -> outcome({:error, e}, plugin_id(compiled))
  catch
    kind, value -> fail(plugin_id(compiled), {kind, value})
  end

  defp quarantine(plugin) do
    fun =
      :chimera_runtime
      |> Application.get_env(ChimeraRuntime.Orchestration, [])
      |> Keyword.get(:quarantine_fun, &Sandbox.quarantine_plugin/1)

    fun.(plugin)
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp outcome({:ok, _}, _id), do: :ok
  defp outcome(:ok, _id), do: :ok

  defp outcome({:error, error}, id) do
    if transient?(error), do: :retry, else: fail(id, error)
  end

  defp outcome(other, id), do: fail(id, {:unexpected_result, other})

  defp fail(id, reason) do
    Logger.error(
      "publish saga compensation failed for plugin #{inspect(id)}: #{inspect(reason, limit: 20)}"
    )

    {:error, reason}
  end

  defp transient?(error) when is_exception(error) do
    message = safe_message(error)
    String.contains?(message, "database is locked") or String.contains?(message, "busy")
  end

  defp transient?(_), do: false

  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> ""
  end

  defp plugin_id(%{id: id}), do: id
  defp plugin_id(_), do: nil
end
