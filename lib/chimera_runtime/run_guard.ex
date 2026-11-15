defmodule ChimeraRuntime.RunGuard do
  @moduledoc """
  Run_Capacity_Guard: a soft limit on concurrently active Workers.

  `check/0` compares the number of active children of
  `ChimeraRuntime.Runner.TaskSupervisor` with the configured `max_workers`
  (default 8). No lock is held, so the limit is approximate by design.
  """

  @default_max_workers 8

  @doc "Pure decision: `:ok` when `active < max`, otherwise `{:error, :busy}`."
  @spec decide(non_neg_integer(), pos_integer()) :: :ok | {:error, :busy}
  def decide(active, max) when is_integer(active) and is_integer(max) and active < max, do: :ok
  def decide(active, max) when is_integer(active) and is_integer(max), do: {:error, :busy}

  @doc "Reads the active Worker count and configured capacity, then decides."
  @spec check() :: :ok | {:error, :busy}
  def check do
    active = Supervisor.count_children(ChimeraRuntime.Runner.TaskSupervisor).active
    decide(active, max_workers())
  end

  defp max_workers do
    :chimera_runtime
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_workers, @default_max_workers)
  end
end
