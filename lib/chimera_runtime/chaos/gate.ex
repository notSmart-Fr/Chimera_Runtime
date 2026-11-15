defmodule ChimeraRuntime.Chaos.Gate do
  @moduledoc """
  Global single-flight gate with a cooldown for chaos runs.

  The decision logic lives in the pure `decide/3`. The GenServer owns the state,
  monitors the process that acquired the gate, and releases the slot (starting the
  cooldown) when that process exits without calling `release/1`.

  State is `%{in_flight: nil | reference, last_end: nil | integer}`. Times are
  monotonic milliseconds. The cooldown comes from
  `config :chimera_runtime, :chaos, cooldown_ms: n` (default 2000).
  """

  use GenServer

  @default_cooldown_ms 2000

  @type gate_state :: %{in_flight: nil | reference(), last_end: nil | integer()}

  @doc "Returns the initial pure gate state."
  @spec new_state() :: gate_state()
  def new_state, do: %{in_flight: nil, last_end: nil}

  @doc """
  Pure decision function.

  `:acquire` returns `{:error, :in_flight}` while a run is in flight,
  `{:error, {:cooldown, remaining_ms}}` inside the cooldown, otherwise `{:ok, state}`
  with a fresh `in_flight` reference. `:release` clears the slot and records `now`
  as `last_end`. Releasing an idle gate leaves the state unchanged.
  """
  @spec decide(gate_state(), :acquire | :release, integer()) ::
          {:ok, gate_state()} | {:error, :in_flight | {:cooldown, pos_integer()}}
  def decide(%{in_flight: ref}, :acquire, _now) when is_reference(ref), do: {:error, :in_flight}

  def decide(%{last_end: last_end} = state, :acquire, now) when is_integer(last_end) do
    remaining = last_end + cooldown_ms() - now

    if remaining > 0 do
      {:error, {:cooldown, remaining}}
    else
      {:ok, %{state | in_flight: make_ref()}}
    end
  end

  def decide(state, :acquire, _now), do: {:ok, %{state | in_flight: make_ref()}}

  def decide(%{in_flight: ref} = state, :release, now) when is_reference(ref),
    do: {:ok, %{state | in_flight: nil, last_end: now}}

  def decide(state, :release, _now), do: {:ok, state}

  @doc "Configured cooldown in milliseconds."
  @spec cooldown_ms() :: non_neg_integer()
  def cooldown_ms do
    :chimera_runtime
    |> Application.get_env(:chaos, [])
    |> Keyword.get(:cooldown_ms, @default_cooldown_ms)
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Tries to take the gate on behalf of `pid` (the gate monitors it).

  Returns `{:ok, ref}`, `{:error, :in_flight}`, or `{:error, {:cooldown, remaining_ms}}`.
  """
  @spec acquire(pid(), GenServer.server()) ::
          {:ok, reference()} | {:error, :in_flight | {:cooldown, pos_integer()}}
  def acquire(pid \\ self(), server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:acquire, pid})

  @doc "Releases the slot identified by `ref` and starts the cooldown. Stale refs are ignored."
  @spec release(reference(), GenServer.server()) :: :ok
  def release(ref, server \\ __MODULE__) when is_reference(ref),
    do: GenServer.call(server, {:release, ref})

  # Server

  @impl true
  def init(:ok), do: {:ok, %{gate: new_state(), monitor: nil}}

  @impl true
  def handle_call({:acquire, pid}, _from, %{gate: gate} = state) do
    case decide(gate, :acquire, now()) do
      {:ok, %{in_flight: ref} = new_gate} ->
        monitor = Process.monitor(pid)
        {:reply, {:ok, ref}, %{state | gate: new_gate, monitor: monitor}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:release, ref}, _from, %{gate: %{in_flight: ref}} = state) do
    {:reply, :ok, finish(state)}
  end

  def handle_call({:release, _stale_ref}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:noreply, finish(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(%{gate: gate, monitor: monitor} = state) do
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:ok, new_gate} = decide(gate, :release, now())
    %{state | gate: new_gate, monitor: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
