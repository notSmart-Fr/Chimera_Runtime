defmodule ChimeraRuntime.Orchestration.PublishPluginReactor do
  @moduledoc """
  Publish saga: moves a Plugin `:draft` -> `:compiling`, runs one Gravedigger
  verification, then moves it to `:active`. A failure after the compile step
  quarantines the Plugin through `Steps.BeginCompile.undo/4`.

  Use `publish/3`. It always returns exactly one tuple and never raises, exits
  or throws.
  """

  use Ash.Reactor

  alias ChimeraRuntime.Orchestration.Result
  alias ChimeraRuntime.Orchestration.Steps.{BeginCompile, LoadPlugin, Promote, Verify}
  alias ChimeraRuntime.Sandbox

  ash do
    default_domain ChimeraRuntime.Sandbox
  end

  input :plugin_id
  input :function_name
  input :args

  step :load_plugin, LoadPlugin do
    argument :plugin_id, input(:plugin_id)
    argument :function_name, input(:function_name)
    argument :args, input(:args)
    async? false
    max_retries 0
  end

  step :begin_compile, BeginCompile do
    argument :plugin, result(:load_plugin)
    async? false
    max_retries 0
  end

  step :verify, Verify do
    argument :plugin, result(:begin_compile)
    argument :function_name, input(:function_name)
    argument :args, input(:args)
    async? false
    max_retries 0
  end

  step :promote, Promote do
    argument :plugin, result(:begin_compile)
    argument :verification, result(:verify)
    async? false
    max_retries 0
  end

  collect :published do
    argument :plugin, result(:promote)
    argument :verification, result(:verify)
  end

  return :published

  @type success :: {:ok, %{plugin: struct(), verification: %{output: term()}}}
  @type failure ::
          {:error, %{stage: atom(), reason: term(), plugin_state: atom(), compensation: term()}}

  @doc """
  Publishes the Plugin `plugin_id`. Returns `{:ok, %{plugin: plugin, verification: %{output: output}}}`
  or `{:error, %{stage:, reason:, plugin_state:, compensation:}}`.
  """
  @spec publish(term(), term(), term()) :: success() | failure()
  def publish(plugin_id, function_name, args \\ []) do
    do_publish(plugin_id, function_name, args)
  rescue
    e -> unexpected(plugin_id, {:raised, Exception.message(e)})
  catch
    kind, value -> unexpected(plugin_id, {kind, inspect(value, limit: 20)})
  end

  defp do_publish(plugin_id, function_name, args)
       when is_binary(plugin_id) and is_binary(function_name) and is_list(args) and
              byte_size(function_name) in 1..255 and length(args) <= 64 do
    case Ecto.UUID.cast(plugin_id) do
      {:ok, uuid} -> locked(uuid, function_name, args)
      :error -> invalid(plugin_id)
    end
  end

  defp do_publish(plugin_id, _function_name, _args), do: invalid(plugin_id)

  defp invalid(plugin_id) do
    Result.error(:preflight, {:invalid_input, :publish_arguments}, plugin_state(plugin_id))
  end

  defp locked(plugin_id, function_name, args) do
    lock = {{__MODULE__, plugin_id}, self()}

    case :global.trans(lock, fn -> run_saga(plugin_id, function_name, args) end, [node()], 0) do
      :aborted -> Result.error(:lock, :publish_in_progress, plugin_state(plugin_id))
      result -> result
    end
  end

  defp run_saga(plugin_id, function_name, args) do
    inputs = %{plugin_id: plugin_id, function_name: function_name, args: args}

    case Reactor.run(__MODULE__, inputs, %{}, async?: false, timeout: :infinity) do
      {:ok, %{plugin: plugin, verification: %{output: _} = verification}} ->
        {:ok, %{plugin: plugin, verification: verification}}

      {:ok, other} ->
        Result.error(
          :promote,
          {:unexpected_result, inspect(other, limit: 20)},
          plugin_state(plugin_id)
        )

      {:error, error} ->
        error |> Result.from_reactor_error() |> Result.error(plugin_state(plugin_id))

      other ->
        Result.error(:verify, {:unexpected, inspect(other, limit: 20)}, plugin_state(plugin_id))
    end
  end

  defp unexpected(plugin_id, reason) do
    Result.error(:verify, {:unexpected, reason}, plugin_state(plugin_id))
  rescue
    _ ->
      {:error,
       %{
         stage: :verify,
         reason: {:unexpected, reason},
         plugin_state: :unknown,
         compensation: :not_needed
       }}
  end

  defp plugin_state(plugin_id) do
    case Sandbox.get_plugin(plugin_id, not_found_error?: false) do
      {:ok, %{state: state}} when state in [:draft, :compiling, :active, :quarantined] -> state
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end
end
