defmodule ChimeraRuntime.Runner.Worker do
  @moduledoc """
  Pure Wasmex invocation. Runs inside the Worker process started by the Engine.

  WASI is disabled (the store is built with `Wasmex.Store.new/2`) and the imports
  map is empty, so any declared import fails instantiation. Every run uses a
  fuel-enabled engine with a finite budget set before any call.

  The out-of-fuel trap message from Wasmex 0.16.0 is
  `"Error during function excecution (wasm trap: all fuel consumed by WebAssembly): ..."`.
  Wasmex misspells "excecution", so only the substring below is matched.
  """

  alias Wasmex.{Engine, EngineConfig, Module, Store, StoreOrCaller}

  @fuel_marker "all fuel consumed by WebAssembly"
  @default_fuel_budget 10_000_000

  @type reason ::
          {:compile_error, String.t()}
          | {:instantiation_error, String.t()}
          | {:unsatisfied_import, String.t()}
          | {:missing_export, String.t()}
          | {:fuel_exhausted, String.t()}
          | {:trap, String.t()}
          | {:call_error, String.t()}

  @doc """
  Compiles `binary`, instantiates it and calls `function_name` with `args`.

  Returns `{:ok, values}` or `{:error, reason}`. Sets `trap_exit` on the calling
  (Worker) process only.
  """
  @spec invoke(binary(), String.t(), list()) :: {:ok, list()} | {:error, reason()}
  def invoke(binary, function_name, args) do
    Process.flag(:trap_exit, true)

    with {:ok, store} <- build_store(),
         {:ok, module} <- compile(store, binary),
         {:ok, pid} <- start_instance(store, module) do
      try do
        with :ok <- check_export(module, function_name) do
          call(pid, function_name, args)
        end
      after
        stop_instance(pid)
      end
    end
  end

  @doc """
  Builds a fuel-enabled, WASI-free store with the configured fuel budget set.
  """
  @spec build_store() :: {:ok, StoreOrCaller.t()} | {:error, reason()}
  def build_store do
    with {:ok, engine} <- Engine.new(%EngineConfig{consume_fuel: true}),
         {:ok, store} <- Store.new(nil, engine),
         :ok <- StoreOrCaller.set_fuel(store, fuel_budget()) do
      {:ok, store}
    else
      {:error, msg} -> {:error, {:instantiation_error, format(msg)}}
    end
  end

  defp fuel_budget do
    :chimera_runtime
    |> Application.get_env(ChimeraRuntime.Runner.Engine, [])
    |> Keyword.get(:fuel_budget, @default_fuel_budget)
  end

  defp compile(store, binary) do
    case Module.compile(store, binary) do
      {:ok, module} -> {:ok, module}
      {:error, msg} -> {:error, {:compile_error, format(msg)}}
    end
  rescue
    e -> {:error, {:compile_error, Exception.message(e)}}
  end

  # `Wasmex.start_link/1` links to this process. A failing `init/1` (for example an
  # unsatisfied import, which raises a MatchError) comes back as `{:error, _}` and/or
  # an EXIT message, which `trap_exit` turns into a message instead of a crash.
  defp start_instance(store, module) do
    result =
      try do
        Wasmex.start_link(%{store: store, module: module, imports: %{}})
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        flush_exits()
        {:error, classify_start_error(reason)}
    end
  end

  defp classify_start_error(reason) do
    msg = format(reason)

    if unsatisfied_import?(reason, msg) do
      {:unsatisfied_import, msg}
    else
      {:instantiation_error, msg}
    end
  end

  defp unsatisfied_import?({%MatchError{}, _stack}, _msg), do: true
  defp unsatisfied_import?(_reason, msg), do: String.contains?(String.downcase(msg), "import")

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp check_export(module, function_name) do
    case Module.exports(module) do
      %{^function_name => {:fn, _params, _results}} -> :ok
      _ -> {:error, {:missing_export, function_name}}
    end
  end

  defp call(pid, function_name, args) do
    case Wasmex.call_function(pid, function_name, args) do
      {:ok, values} -> {:ok, values}
      {:error, msg} -> {:error, classify_call_error(format(msg))}
    end
  catch
    :exit, reason -> {:error, {:call_error, format(reason)}}
  end

  # Fuel exhaustion also surfaces as a trap, so it is matched first.
  defp classify_call_error(msg) do
    cond do
      String.contains?(msg, @fuel_marker) -> {:fuel_exhausted, msg}
      String.contains?(msg, "trap") -> {:trap, msg}
      true -> {:call_error, msg}
    end
  end

  defp stop_instance(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  after
    flush_exits()
  end

  defp format(msg) when is_binary(msg), do: msg
  defp format(other), do: inspect(other, limit: 50, printable_limit: 500)
end
