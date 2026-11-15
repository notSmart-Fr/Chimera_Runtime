defmodule ChimeraRuntime.Vitals do
  @moduledoc """
  BEAM telemetry for the control room.

  `collect/1` reads VM values and returns a fixed-key map plus the new
  `:scheduler` sample, or `:error` if any read fails. It never raises.
  """

  @memory_keys [:total, :processes, :binary, :ets, :code]

  @type sample :: term()
  @type t :: %{
          memory: %{
            total: non_neg_integer(),
            processes: non_neg_integer(),
            binary: non_neg_integer(),
            ets: non_neg_integer(),
            code: non_neg_integer()
          },
          schedulers_online: non_neg_integer(),
          dirty_cpu_schedulers_online: non_neg_integer(),
          run_queue: non_neg_integer(),
          process_count: non_neg_integer(),
          active_workers: non_neg_integer(),
          utilization_percent: float()
        }

  @doc """
  Collects a telemetry snapshot. `prev` is the previous sample returned by this
  function, or `nil` for the first call (utilization is then `0.0`).
  """
  @spec collect(sample() | nil) :: {:ok, t(), sample()} | :error
  def collect(prev) do
    memory = :erlang.memory()
    current = :scheduler.sample_all()

    vitals = %{
      memory: Map.new(@memory_keys, &{&1, Keyword.fetch!(memory, &1)}),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      process_count: :erlang.system_info(:process_count),
      active_workers: Supervisor.count_children(ChimeraRuntime.Runner.TaskSupervisor).active,
      utilization_percent: utilization(prev, current)
    }

    {:ok, vitals, current}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  Converts a utilization fraction (0.0 to 1.0) to a percentage clamped to
  0.0..100.0. Non-numeric input yields `0.0`.
  """
  @spec utilization_percent(number()) :: float()
  def utilization_percent(fraction) when is_number(fraction) do
    (fraction * 100.0) |> max(0.0) |> min(100.0)
  end

  def utilization_percent(_), do: 0.0

  defp utilization(nil, _current), do: 0.0

  defp utilization(prev, current) do
    prev
    |> :scheduler.utilization(current)
    |> Enum.find_value(0.0, fn
      {:total, fraction, _} -> fraction
      _ -> nil
    end)
    |> utilization_percent()
  end
end
