defmodule ChimeraRuntimeWeb.DashboardLive do
  @moduledoc """
  The Control Room: plugin registry, console, BEAM vitals, chaos chamber and a
  live execution log.

  ## Demo exposure note

  This page is deliberately open: it sits behind no authentication, so anyone who can
  reach `/control-room` can run active plugins and inject chaos. The only safeguards
  are the run capacity guard (`ChimeraRuntime.RunGuard`) and the chaos gate
  (`ChimeraRuntime.Chaos.Gate`). They limit load. They give no access control. The page
  never shows `wasm_binary` or `source_code` and has no button that edits, destroys or
  quarantines a plugin. To restrict access, add a plug to the `:control_room_access`
  pipeline in the router.

  ## Routing

  Expected route: `live "/control-room", DashboardLive` inside
  `scope "/", ChimeraRuntimeWeb do pipe_through [:browser, :control_room_access] end`,
  with no `live_session` (no `on_mount` hooks and no `current_scope`).
  """
  use ChimeraRuntimeWeb, :live_view

  require Ash.Query

  import ChimeraRuntimeWeb.ControlRoomComponents

  alias ChimeraRuntime.Chaos
  alias ChimeraRuntime.RunGuard
  alias ChimeraRuntime.Runner.Engine
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.Sandbox.EventPayload
  alias ChimeraRuntime.Sandbox.Plugin
  alias ChimeraRuntime.Vitals
  alias ChimeraRuntimeWeb.ControlRoom.ArgsCodec
  alias ChimeraRuntimeWeb.ControlRoom.Refresh

  @refresh_delay_ms 250
  @vitals_interval_ms 1_000
  @fallback_interval_ms 30_000
  @log_limit 50
  @registry_id "plugin-registry"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ChimeraRuntime.PubSub, "sandbox:executions")
      Phoenix.PubSub.subscribe(ChimeraRuntime.PubSub, "sandbox:plugins")
      :timer.send_interval(@vitals_interval_ms, :vitals_tick)
      :timer.send_interval(@fallback_interval_ms, :fallback_refresh)
      send(self(), :vitals_tick)
    end

    socket =
      socket
      |> assign(:page_title, "Control Room")
      |> assign(:registry_query, Ash.Query.select(Plugin, [:id, :name, :state, :timeout_ms]))
      |> assign(
        :console_form,
        console_form(%{"plugin_id" => "", "function_name" => "", "args" => ""})
      )
      |> assign(:console, :idle)
      |> assign(:chaos, :idle)
      |> assign(:chaos_lv, nil)
      |> assign(:vitals, %{})
      |> assign(:vitals_stale?, false)
      |> assign(:last_sched_sample, nil)
      |> assign(:refresh_ref, nil)
      |> assign(:selector_dirty?, false)
      |> stream(:log, [], limit: @log_limit)
      |> load_active_plugins()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto w-full max-w-6xl space-y-6 px-2 py-6">
        <.demo_banner />
        <.registry_panel registry_query={@registry_query} />
        <div class="grid gap-6 lg:grid-cols-2">
          <.console_panel form={@console_form} plugins={@active_plugins} state={@console} />
          <.vitals_panel
            vitals={@vitals}
            stale?={@vitals_stale?}
            chaos={@chaos}
            log={@streams.log}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Events ---------------------------------------------------------------

  @impl true
  def handle_event("console_validate", params, socket) do
    form_params = form_params(params)

    {:noreply, assign(socket, :console_form, console_form(form_params, args_errors(form_params)))}
  end

  def handle_event("console_run", _params, %{assigns: %{console: :running}} = socket),
    do: {:noreply, socket}

  def handle_event("console_run", params, socket) do
    form_params = form_params(params)
    plugin_id = form_params["plugin_id"]
    function_name = form_params["function_name"]

    with :ok <- require_present(plugin_id, "Select a plugin"),
         :ok <- require_present(function_name, "Enter a function name"),
         {:ok, args} <- parse_args(form_params["args"]) do
      socket =
        socket
        |> assign(:console_form, console_form(form_params))
        |> assign(:console, :running)
        |> start_async(:console_run, fn -> run_console(plugin_id, function_name, args) end)

      {:noreply, socket}
    else
      {:error, field, message} ->
        errors = [{field, {message, []}}]
        {:noreply, assign(socket, :console_form, console_form(form_params, errors))}
    end
  end

  def handle_event("inject_chaos", _params, %{assigns: %{chaos: :running}} = socket),
    do: {:noreply, socket}

  def handle_event("inject_chaos", _params, socket) do
    socket =
      socket
      |> assign(:chaos, :running)
      |> assign(:chaos_lv, self())
      |> start_async(:chaos_run, &run_chaos/0)

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- Async results ----------------------------------------------------------

  @impl true
  def handle_async(:console_run, {:ok, {:ran, result, wall_us}}, socket) do
    {:noreply, assign(socket, :console, console_state(result, wall_us))}
  end

  def handle_async(:console_run, {:ok, {:rejected, reason}}, socket) do
    {:noreply, assign(socket, :console, {:rejected, reason})}
  end

  def handle_async(:console_run, {:exit, reason}, socket) do
    {:noreply, assign(socket, :console, {:rejected, {:error, exit_message(reason)}})}
  end

  def handle_async(:chaos_run, {:ok, {:ran, result, wall_us}}, socket) do
    same? = same_process?(socket.assigns.chaos_lv)
    {:noreply, assign(socket, :chaos, {:done, chaos_outcome(result, wall_us, same?)})}
  end

  def handle_async(:chaos_run, {:ok, {:rejected, reason}}, socket) do
    {:noreply, assign(socket, :chaos, {:rejected, reason})}
  end

  def handle_async(:chaos_run, {:exit, reason}, socket) do
    {:noreply, assign(socket, :chaos, {:rejected, {:error, exit_message(reason)}})}
  end

  # -- Messages ---------------------------------------------------------------

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "sandbox:executions",
          event: "execution_recorded",
          payload: payload
        },
        socket
      ) do
    if EventPayload.valid_execution?(payload) do
      socket = stream_insert(socket, :log, payload, at: 0, limit: @log_limit)
      {:noreply, schedule_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "sandbox:plugins",
          event: "plugin_changed",
          payload: payload
        },
        socket
      ) do
    if EventPayload.valid_plugin?(payload) do
      {:noreply, socket |> assign(:selector_dirty?, true) |> schedule_refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:flush_refresh, socket), do: {:noreply, flush_refresh(socket)}

  def handle_info(:fallback_refresh, socket) do
    Cinder.Refresh.refresh_table(socket, @registry_id, silent: true)
    {:noreply, socket}
  end

  def handle_info(:vitals_tick, socket) do
    case Vitals.collect(socket.assigns.last_sched_sample) do
      {:ok, vitals, sample} ->
        {:noreply,
         assign(socket, vitals: vitals, vitals_stale?: false, last_sched_sample: sample)}

      :error ->
        {:noreply, assign(socket, :vitals_stale?, true)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # -- Refresh ----------------------------------------------------------------

  defp schedule_refresh(socket) do
    case Refresh.on_event(socket.assigns.refresh_ref, @refresh_delay_ms) do
      {:schedule, delay} ->
        assign(socket, :refresh_ref, Process.send_after(self(), :flush_refresh, delay))

      :already_scheduled ->
        socket
    end
  end

  defp flush_refresh(socket) do
    Cinder.Refresh.refresh_table(socket, @registry_id, silent: true)

    socket = if socket.assigns.selector_dirty?, do: load_active_plugins(socket), else: socket
    assign(socket, refresh_ref: nil, selector_dirty?: false)
  end

  defp load_active_plugins(socket) do
    assign_async(socket, :active_plugins, fn ->
      query =
        Plugin
        |> Ash.Query.filter(state == :active)
        |> Ash.Query.select([:id, :name])
        |> Ash.Query.sort(:name)

      case Ash.read(query, domain: Sandbox) do
        {:ok, plugins} -> {:ok, %{active_plugins: Enum.map(plugins, &{&1.name, &1.id})}}
        {:error, _} -> {:error, :plugins_unavailable}
      end
    end)
  end

  # -- Console ----------------------------------------------------------------

  # Runs in the async task, not in the LiveView.
  defp run_console(plugin_id, function_name, args) do
    with {:ok, plugin} <- read_plugin(plugin_id),
         :ok <- RunGuard.check() do
      started = System.monotonic_time()
      result = Engine.run(plugin, function_name, args, run_mode: :standard)
      {:ran, result, wall_us(started)}
    else
      {:error, :busy} -> {:rejected, :busy}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp read_plugin(id) do
    case Sandbox.get_plugin(id) do
      {:ok, %Plugin{} = plugin} -> {:ok, plugin}
      _ -> {:error, {:error, "Plugin not found or could not be read"}}
    end
  end

  defp console_state({:error, :plugin_not_active}, _wall_us), do: {:rejected, :plugin_not_active}

  defp console_state({:ok, values}, wall_us) do
    {:done, %{status: :success, output: format_output(values), reason: nil, wall_us: wall_us}}
  end

  defp console_state({:error, reason} = result, wall_us) do
    {:done,
     %{
       status: Engine.status_for(result),
       output: nil,
       reason: Engine.format_reason(reason),
       wall_us: wall_us
     }}
  end

  defp format_output(values) do
    if is_list(values) and Enum.all?(values, &is_number/1) do
      ArgsCodec.print(values)
    else
      inspect(values, limit: 20, printable_limit: 500)
    end
  rescue
    _ -> inspect(values, limit: 20, printable_limit: 500)
  end

  defp parse_args(text) do
    case ArgsCodec.parse(text || "") do
      {:ok, args} -> {:ok, args}
      {:error, reason} -> {:error, :args, args_message(reason)}
    end
  end

  defp args_errors(%{"args" => text}) do
    case ArgsCodec.parse(text) do
      {:ok, _} -> []
      {:error, reason} -> [args: {args_message(reason), []}]
    end
  end

  defp args_errors(_), do: []

  defp args_message(:too_large), do: "Arguments are larger than 4096 bytes"
  defp args_message(:invalid_json), do: "Arguments are not valid JSON"
  defp args_message({:not_array, kind}), do: "Arguments must be a JSON array, got #{kind}"
  defp args_message({:too_many, n}), do: "At most 64 arguments are allowed, got #{n}"

  defp args_message({:bad_element, index, kind}),
    do: "Argument #{index} must be a number, got #{kind}"

  defp require_present(value, message) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, field_for(message), message}
    end
  end

  defp field_for("Select a plugin"), do: :plugin_id
  defp field_for(_), do: :function_name

  defp form_params(%{"console" => %{} = params}), do: normalize_params(params)
  defp form_params(%{} = params), do: normalize_params(params)

  defp normalize_params(params) do
    %{
      "plugin_id" => string_param(params["plugin_id"]),
      "function_name" => string_param(params["function_name"]),
      "args" => string_param(params["args"])
    }
  end

  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: ""

  defp console_form(params, errors \\ []), do: to_form(params, as: :console, errors: errors)

  # -- Chaos ------------------------------------------------------------------

  # Runs in the async task, not in the LiveView. The gate monitors this task, so the slot
  # is freed (and the cooldown starts) even if the task is killed.
  defp run_chaos do
    with :ok <- check_fuel_budget(),
         {:ok, ref} <- Chaos.Gate.acquire(self()) do
      try do
        run_chaos_plugin()
      after
        Chaos.Gate.release(ref)
      end
    else
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp run_chaos_plugin do
    with {:ok, plugin} <- ensure_chaos_plugin(),
         :ok <- RunGuard.check() do
      started = System.monotonic_time()
      result = Engine.run(plugin, "run", [], run_mode: :standard)
      {:ran, result, wall_us(started)}
    else
      {:error, :busy} -> {:rejected, :busy}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp ensure_chaos_plugin do
    case Chaos.Plugin.ensure_active() do
      {:ok, plugin} -> {:ok, plugin}
      {:error, {:not_active, state}} -> {:error, {:plugin_state, state}}
      {:error, _reason} -> {:error, {:error, "chaos-chamber plugin is unavailable"}}
    end
  end

  defp check_fuel_budget do
    budget =
      :chimera_runtime
      |> Application.get_env(Engine, [])
      |> Keyword.get(:fuel_budget)

    if is_integer(budget) and budget > 0, do: :ok, else: {:error, :fuel_not_configured}
  end

  defp chaos_outcome({:error, :timeout} = result, wall_us, same?),
    do: contained(result, :timeout, wall_us, same?)

  defp chaos_outcome({:error, {:fuel_exhausted, _}} = result, wall_us, same?),
    do: contained(result, :fuel_exhausted, wall_us, same?)

  defp chaos_outcome({:error, reason}, wall_us, same?) do
    %{
      outcome: :unexpected,
      kind: :error,
      reason: Engine.format_reason(reason),
      wall_us: wall_us,
      same_process?: same?
    }
  end

  defp chaos_outcome({:ok, _}, wall_us, same?) do
    %{
      outcome: :unexpected,
      kind: :ok,
      reason: "the infinite loop returned",
      wall_us: wall_us,
      same_process?: same?
    }
  end

  defp contained({:error, reason}, kind, wall_us, same?) do
    %{
      outcome: :contained,
      kind: kind,
      reason: Engine.format_reason(reason),
      wall_us: wall_us,
      same_process?: same?
    }
  end

  defp same_process?(lv) when is_pid(lv), do: lv == self() and Process.alive?(lv)
  defp same_process?(_), do: false

  # -- Helpers ----------------------------------------------------------------

  defp wall_us(started) do
    (System.monotonic_time() - started)
    |> System.convert_time_unit(:native, :microsecond)
    |> max(0)
  end

  defp exit_message({%{__exception__: true} = e, _stack}),
    do: "run failed: " <> Exception.message(e)

  defp exit_message(reason), do: "run failed: " <> inspect(reason, limit: 5, printable_limit: 200)
end
