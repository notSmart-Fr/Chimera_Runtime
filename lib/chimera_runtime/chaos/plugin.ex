defmodule ChimeraRuntime.Chaos.Plugin do
  @moduledoc """
  The persisted `chaos-chamber` system Plugin used by the Control_Room chaos button.

  The module exports `run() -> ()` and loops forever, so every run is ended by the
  deadline. `ensure_active/0` is idempotent and never runs the Gravedigger.
  """

  require Ash.Query

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Plugin

  @name "chaos-chamber"
  @default_deadline_ms 250
  @min_deadline_ms 10
  @max_deadline_ms 1000

  # Hand-assembled infinite-loop module (same bytes as ChimeraRuntime.WasmFixtures.infinite_loop/0).
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
          0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00, 0x0A, 0x09, 0x01,
          0x07, 0x00, 0x03, 0x40, 0x0C, 0x00, 0x0B, 0x0B>>

  @doc "The Plugin name."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The infinite-loop Wasm binary."
  @spec wasm() :: binary()
  def wasm, do: @wasm

  @doc """
  Returns `{:ok, plugin}` with the active `chaos-chamber` Plugin, creating, compiling and
  activating it when absent. Returns `{:error, {:not_active, state}}` when it exists in
  another state (the Plugin is not modified), or `{:error, reason}` on failure.
  """
  @spec ensure_active() :: {:ok, Plugin.t()} | {:error, term()}
  def ensure_active do
    with {:ok, timeout_ms} <- deadline_ms(),
         {:ok, plugin} <- fetch_or_create(timeout_ms) do
      case plugin.state do
        :active -> {:ok, plugin}
        state -> {:error, {:not_active, state}}
      end
    end
  end

  defp fetch_or_create(timeout_ms) do
    case read_existing() do
      {:ok, nil} -> create_and_activate(timeout_ms)
      {:ok, plugin} -> {:ok, plugin}
      {:error, _} = error -> error
    end
  end

  defp create_and_activate(timeout_ms) do
    attrs = %{name: @name, wasm_binary: @wasm, timeout_ms: timeout_ms}

    case Sandbox.create_plugin(attrs) do
      {:ok, plugin} ->
        with {:ok, plugin} <- Sandbox.compile_plugin(plugin) do
          Sandbox.activate_plugin(plugin)
        end

      {:error, error} ->
        if unique_name_error?(error), do: read_required(), else: {:error, error}
    end
  end

  defp read_required do
    case read_existing() do
      {:ok, nil} -> {:error, :chaos_plugin_unavailable}
      other -> other
    end
  end

  defp read_existing do
    Plugin
    |> Ash.Query.filter(name == ^@name)
    |> Ash.read_one(domain: Sandbox)
  end

  defp unique_name_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{field: :name} -> true
      _ -> false
    end)
  end

  defp unique_name_error?(_), do: false

  defp deadline_ms do
    config = Application.get_env(:chimera_runtime, :chaos, [])

    case Keyword.get(config, :deadline_ms, @default_deadline_ms) do
      ms when is_integer(ms) and ms >= @min_deadline_ms and ms <= @max_deadline_ms -> {:ok, ms}
      other -> {:error, {:invalid_deadline_ms, other}}
    end
  end
end
