defmodule ChimeraRuntime.Runner.Engine do
  @moduledoc """
  Isolation engine for Wasm plugins. A plain module, not a GenServer: every step
  runs in the Caller process except the Wasmex invocation, which runs in one
  unlinked Worker started under `ChimeraRuntime.Runner.TaskSupervisor`.

  `run/4` is total. For any input it returns exactly one of `{:ok, values}` or
  `{:error, reason}` and never raises, exits or throws into the Caller.

  Flow: validate input, validate timeout, gate, consume the verification one-shot
  (`consume_verification/2`, filled in by task 5.3), run the Worker with a
  deadline, then record the Execution (`record_execution/2`, filled in by task 5.3).
  """

  require Logger

  alias ChimeraRuntime.Runner.Worker
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.Plugin

  @task_supervisor ChimeraRuntime.Runner.TaskSupervisor
  @max_duration_ms 2_147_483_647
  @min_timeout_ms 1
  @max_timeout_ms 600_000
  @max_function_name_bytes 255
  @max_args 64
  @max_reason_chars 1000

  @type run_mode :: :standard | :verification
  @type result :: {:ok, list()} | {:error, atom() | tuple()}

  @doc """
  Runs `function_name` of `plugin` with `args`.

  Options: `:run_mode` (`:standard` by default, or `:verification`).
  """
  @spec run(term(), term(), term(), term()) :: result()
  def run(plugin, function_name, args, opts \\ []) do
    with {:ok, run_mode} <- validate_input(plugin, function_name, args, opts),
         {:ok, timeout_ms} <- validate_timeout(plugin.timeout_ms),
         :ok <- gate(gate_input(plugin, run_mode)),
         :ok <- consume_verification(plugin, run_mode) do
      execute(plugin, function_name, args, run_mode, timeout_ms)
    end
  rescue
    e -> {:error, {:runtime_failure, detail(e)}}
  catch
    kind, value -> {:error, {:runtime_failure, {kind, detail(value)}}}
  end

  @doc """
  Validates plugin, function name, arguments and options. Returns the run mode.
  """
  @spec validate_input(term(), term(), term(), term()) ::
          {:ok, run_mode()} | {:error, {:invalid_input, atom()}}
  def validate_input(plugin, function_name, args, opts) do
    cond do
      not match?(%Plugin{}, plugin) ->
        {:error, {:invalid_input, :plugin}}

      not valid_function_name?(function_name) ->
        {:error, {:invalid_input, :function_name}}

      not valid_args?(args) ->
        {:error, {:invalid_input, :args}}

      not Keyword.keyword?(opts) ->
        {:error, {:invalid_input, :opts}}

      true ->
        case Keyword.get(opts, :run_mode, :standard) do
          mode when mode in [:standard, :verification] -> {:ok, mode}
          _ -> {:error, {:invalid_input, :run_mode}}
        end
    end
  end

  @doc """
  Validates a timeout: an integer in 1..600_000.
  """
  @spec validate_timeout(term()) :: {:ok, pos_integer()} | {:error, :invalid_timeout}
  def validate_timeout(timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= @min_timeout_ms and
             timeout_ms <= @max_timeout_ms,
      do: {:ok, timeout_ms}

  def validate_timeout(_), do: {:error, :invalid_timeout}

  @doc false
  # Pure gate. Input is `{run_mode, state, has_binary?, verification_used}`.
  # State is checked before the binary, and `:verification_already_used` before
  # `:missing_binary`.
  @spec gate({run_mode(), atom(), boolean(), boolean()}) :: :ok | {:error, atom() | tuple()}
  def gate({:standard, :active, true, _used}), do: :ok
  def gate({:standard, :active, false, _used}), do: {:error, :missing_binary}
  def gate({:standard, _state, _binary?, _used}), do: {:error, :plugin_not_active}

  def gate({:verification, state, _binary?, _used}) when state != :compiling,
    do: {:error, :plugin_not_active}

  def gate({:verification, :compiling, _binary?, true}), do: {:error, :verification_already_used}
  def gate({:verification, :compiling, false, false}), do: {:error, :missing_binary}
  def gate({:verification, :compiling, true, false}), do: :ok
  def gate(_), do: {:error, {:invalid_input, :gate}}

  @doc false
  # Test seam for the wait/shutdown stage: maps the reply of `Task.yield/2` or
  # `Task.shutdown/2` to an outcome. `nil` means no reply and no exit.
  @spec settle(nil | {:ok, term()} | {:exit, term()}) ::
          {:finished, term()} | {:crashed, term()} | nil
  def settle({:ok, result}), do: {:finished, result}
  def settle({:exit, reason}), do: {:crashed, reason}
  def settle(nil), do: nil

  @doc false
  # Maps a Worker outcome to the Engine result.
  @spec outcome_to_result({:finished, term()} | {:crashed, term()} | :timeout) :: result()
  def outcome_to_result({:finished, {:ok, output}}) when is_list(output), do: {:ok, output}
  def outcome_to_result({:finished, {:error, reason}}), do: {:error, reason}

  def outcome_to_result({:finished, other}),
    do: {:error, {:worker_exit, {:unexpected_result, other}}}

  def outcome_to_result({:crashed, reason}), do: {:error, {:worker_exit, reason}}
  def outcome_to_result(:timeout), do: {:error, :timeout}

  @doc false
  # Execution status for a result. Fuel exhaustion counts as a timeout.
  @spec status_for(result()) :: :success | :timeout | :error
  def status_for({:ok, _}), do: :success
  def status_for({:error, :timeout}), do: :timeout
  def status_for({:error, {:fuel_exhausted, _}}), do: :timeout
  def status_for({:error, _}), do: :error

  # -- Hooks filled in by task 5.3 ------------------------------------------

  # For `:verification`, atomically consumes the one-shot from the Caller, before the
  # Worker starts. A filter miss (already used) is `:verification_already_used`; any
  # other failure is `:verification_marker_failed`.
  @doc false
  @spec consume_verification(struct(), run_mode()) :: :ok | {:error, atom()}
  def consume_verification(_plugin, :standard), do: :ok

  def consume_verification(plugin, :verification) do
    case Sandbox.mark_verification_used(plugin) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        if stale?(error), do: {:error, :verification_already_used}, else: marker_failed(error)
    end
  rescue
    e -> marker_failed(e)
  catch
    kind, value -> marker_failed({kind, value})
  end

  defp marker_failed(error) do
    Logger.error("failed to mark verification used: #{detail(error)}")
    {:error, :verification_marker_failed}
  end

  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(_), do: false

  # Persists the Execution from the Caller. `context` has `:plugin`, `:function_name`,
  # `:args`, `:run_mode`, `:timeout_ms`, `:duration_ms`, `:status` and `:result`.
  # Never alters the run result and swallows its own failures (one Logger.error, no retry).
  @doc false
  @spec record_execution(map(), result()) :: :ok
  def record_execution(context, result) do
    recorder =
      Application.get_env(:chimera_runtime, :execution_recorder) || (&Sandbox.create_execution/1)

    attrs = execution_attrs(context, result)

    case safe_record(recorder, attrs) do
      {:ok, _} -> :ok
      other -> log_persist_failure(context, other)
    end
  rescue
    e -> log_persist_failure(context, {:error, e})
  catch
    kind, value -> log_persist_failure(context, {:error, {kind, value}})
  end

  defp safe_record(recorder, attrs) do
    recorder.(attrs)
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp log_persist_failure(context, reason) do
    plugin_id = context |> Map.get(:plugin) |> then(&(is_map(&1) && Map.get(&1, :id)))

    Logger.error(
      "failed to persist execution plugin_id=#{inspect(plugin_id)} reason=#{detail(reason)}"
    )

    :ok
  end

  defp execution_attrs(context, result) do
    status = context.status

    %{
      plugin_id: context.plugin.id,
      input_json: %{"function" => context.function_name, "args" => json_safe(context.args)},
      output_json: output_json(result),
      duration_ms: context.duration_ms |> max(0) |> min(@max_duration_ms),
      status: status,
      error_reason: error_reason(result, context),
      run_mode: context.run_mode
    }
  end

  defp output_json({:ok, values}), do: %{"values" => json_safe(values)}
  defp output_json(_), do: nil

  defp error_reason({:ok, _}, _context), do: nil
  defp error_reason({:error, :timeout}, %{timeout_ms: ms}), do: format_reason({:deadline, ms})
  defp error_reason({:error, reason}, _context), do: format_reason(reason)

  @doc false
  # Non-empty reason string of at most 1000 characters.
  @spec format_reason(term()) :: String.t()
  def format_reason({:deadline, ms}), do: "deadline of #{ms}ms exceeded"
  def format_reason(:timeout), do: "deadline exceeded"

  def format_reason({:fuel_exhausted, msg}) when is_binary(msg),
    do: finalize_reason("fuel exhausted: " <> msg)

  def format_reason({:fuel_exhausted, other}),
    do: finalize_reason("fuel exhausted: " <> detail(other))

  def format_reason(reason), do: finalize_reason(detail(reason))

  defp finalize_reason(text) do
    text =
      text |> String.trim() |> String.codepoints() |> Enum.take(@max_reason_chars) |> Enum.join()

    if String.trim(text) == "", do: "unknown error", else: text
  end

  defp json_safe(value) when is_integer(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  defp json_safe(value) when is_float(value),
    do: if(value - value == 0.0, do: value, else: inspect(value))

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: json_list(value)
  defp json_safe(value), do: inspect(value, limit: 20, printable_limit: 500)

  defp json_list(list) do
    if proper_list?(list), do: Enum.map(list, &json_safe/1), else: inspect(list, limit: 20)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | t]), do: proper_list?(t)
  defp proper_list?(_), do: false
  # -- Internals ------------------------------------------------------------

  defp gate_input(%Plugin{} = plugin, run_mode) do
    {run_mode, plugin.state, is_binary(plugin.wasm_binary), plugin.verification_used == true}
  end

  defp execute(plugin, function_name, args, run_mode, timeout_ms) do
    binary = plugin.wasm_binary
    started = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Worker.invoke(binary, function_name, args)
      end)

    outcome = await(task, timeout_ms)
    duration_ms = clamp_duration(System.monotonic_time(:millisecond) - started)
    result = outcome_to_result(outcome)

    record_execution(
      %{
        plugin: plugin,
        function_name: function_name,
        args: args,
        run_mode: run_mode,
        timeout_ms: timeout_ms,
        duration_ms: duration_ms,
        status: status_for(result),
        result: result
      },
      result
    )

    result
  end

  defp await(task, timeout_ms) do
    case settle(Task.yield(task, timeout_ms)) do
      nil ->
        # Deadline reached. A reply that arrived during shutdown still counts.
        case settle(Task.shutdown(task, :brutal_kill)) do
          nil -> :timeout
          outcome -> outcome
        end

      outcome ->
        outcome
    end
  end

  defp clamp_duration(ms) when ms < 0, do: 0
  defp clamp_duration(ms), do: min(ms, @max_duration_ms)

  defp valid_function_name?(name),
    do: is_binary(name) and byte_size(name) in 1..@max_function_name_bytes

  defp valid_args?(args), do: match?({:ok, n} when n <= @max_args, proper_length(args, 0))

  # `length/1` raises on improper lists, so count by hand and stop past the limit.
  defp proper_length([], n), do: {:ok, n}
  defp proper_length([_ | _], n) when n >= @max_args, do: {:ok, n + 1}
  defp proper_length([_ | rest], n), do: proper_length(rest, n + 1)
  defp proper_length(_, _), do: :error

  defp detail(%{__exception__: true} = e), do: inspect(e, limit: 20, printable_limit: 500)
  defp detail(other), do: inspect(other, limit: 20, printable_limit: 500)
end
