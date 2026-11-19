defmodule ChimeraRuntimeWeb.ControlRoomComponents do
  @moduledoc """
  Function components for the Control Room (`ChimeraRuntimeWeb.DashboardLive`).

  Components are stateless. `DashboardLive` owns all state and passes it in.

  ## State shapes

  Console state (`:state` of `console_panel/1`):

    * `:idle`
    * `:running`
    * `{:done, %{status: :success | :error | :timeout, output: String.t() | nil,
      reason: String.t() | nil, wall_us: non_neg_integer()}}`
    * `{:rejected, reason}` where reason is `:busy`, `:plugin_not_active`,
      `{:read_failed, term}`, or `{:error, message}`

  Chaos state (`:chaos` of `chaos_chamber/1`):

    * `:idle`
    * `:running`
    * `{:done, %{outcome: :contained | :unexpected, kind: term, reason: String.t() | nil,
      wall_us: non_neg_integer(), same_process?: boolean()}}`
    * `{:rejected, reason}` where reason is `:in_flight`, `{:cooldown, ms}`,
      `:fuel_not_configured`, `{:plugin_state, state}`, `:busy`, or any other term
  """
  use Phoenix.Component

  import ChimeraRuntimeWeb.CoreComponents, only: [icon: 1, input: 1]

  alias ChimeraRuntimeWeb.ControlRoom.Format

  @chaos_plugin_name "chaos-chamber"
  @max_reason 300

  @doc "Banner that states the unauthenticated posture of the Control Room."
  def demo_banner(assigns) do
    ~H"""
    <div
      id="demo-banner"
      role="alert"
      class="alert alert-warning alert-soft mb-6 flex items-center gap-3"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <span class="font-medium">Demo mode: open access</span>
    </div>
    """
  end

  @doc "Registry panel: a Cinder collection over the Plugin query (no binary or source selected)."
  attr :registry_query, :any, required: true, doc: "an `Ash.Query` that selects safe fields only"

  def registry_panel(assigns) do
    ~H"""
    <section
      id="registry-panel"
      class="card bg-base-100 border border-base-300 shadow-sm"
      aria-labelledby="registry-title"
    >
      <div class="card-body gap-4">
        <h2 id="registry-title" class="card-title flex items-center gap-2">
          <.icon name="hero-table-cells" class="size-5 text-primary" /> Plugin registry
        </h2>
        <Cinder.collection
          id="plugin-registry"
          query={@registry_query}
          page_size={10}
          theme="daisy_ui"
        >
          <:col :let={p} field="name" filter sort label="Name">
            <span class="font-medium">{p.name}</span>
            <span :if={p.name == chaos_plugin_name()} class="badge badge-warning badge-sm ml-2">
              system
            </span>
          </:col>
          <:col :let={p} field="state" filter={:select} sort label="State">
            <span class={["badge badge-sm", state_class(p.state)]}>{p.state}</span>
          </:col>
          <:col :let={p} field="timeout_ms" label="Timeout">{p.timeout_ms} ms</:col>
          <:col :let={p} field="total_runs" sort label="Runs">{p.total_runs || 0}</:col>
          <:col :let={p} field="failure_rate" sort label="Failure rate">
            {Format.percent(p.failure_rate)}
          </:col>
          <:col :let={p} field="avg_duration_ms" sort label="Avg ms">
            {Format.avg_ms(p.avg_duration_ms)}
          </:col>
          <:empty>No plugins yet</:empty>
          <:error>Registry unavailable, retrying</:error>
        </Cinder.collection>
      </div>
    </section>
    """
  end

  @doc "Console panel: plugin selector, function name, JSON args, Run button and result."
  attr :form, Phoenix.HTML.Form, required: true

  attr :plugins, :any,
    required: true,
    doc: "a `Phoenix.LiveView.AsyncResult` of `{name, id}` options"

  attr :state, :any, default: :idle

  def console_panel(assigns) do
    assigns = assign(assigns, :running?, assigns.state == :running)

    ~H"""
    <section
      id="console-panel"
      class="card bg-base-100 border border-base-300 shadow-sm"
      aria-labelledby="console-title"
    >
      <div class="card-body gap-4">
        <h2 id="console-title" class="card-title flex items-center gap-2">
          <.icon name="hero-command-line" class="size-5 text-primary" /> Console
        </h2>

        <.form
          for={@form}
          id="console-form"
          phx-change="console_validate"
          phx-submit="console_run"
        >
          <.input
            field={@form[:plugin_id]}
            type="select"
            label="Active plugin"
            prompt="Select a plugin"
            options={plugin_options(@plugins)}
            disabled={@running?}
          />
          <.input
            field={@form[:function_name]}
            type="text"
            label="Exported function"
            placeholder="add"
            autocomplete="off"
            disabled={@running?}
          />
          <.input
            field={@form[:args]}
            type="textarea"
            label="Arguments (JSON array of numbers)"
            placeholder="[1, 2]"
            rows="3"
            disabled={@running?}
          />

          <div class="flex items-center gap-3">
            <button
              type="submit"
              id="console-run"
              class="btn btn-primary"
              disabled={@running?}
              phx-disable-with="Running..."
            >
              <.icon name="hero-play" class="size-4" /> Run
            </button>
            <span :if={@running?} id="console-running" class="flex items-center gap-2 text-sm">
              <span class="loading loading-spinner loading-sm"></span> Running
            </span>
          </div>
        </.form>

        <.console_result state={@state} />

        <p class="text-xs text-base-content/60">
          Wall time includes Execution persistence. The stored <code>duration_ms</code>
          is a whole number of milliseconds.
        </p>
      </div>
    </section>
    """
  end

  attr :state, :any, required: true

  defp console_result(%{state: {:done, result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div id="console-result" class="rounded-box border border-base-300 bg-base-200/50 p-4 space-y-2">
      <div class="flex items-center gap-2">
        <span class={["badge", status_class(@result.status)]}>{@result.status}</span>
        <span id="console-wall-time" class="text-sm text-base-content/70">
          Wall time: {Format.duration(@result.wall_us)}
        </span>
      </div>
      <pre
        :if={@result[:output]}
        id="console-output"
        class="overflow-x-auto rounded bg-base-300/60 p-3 text-sm"
      ><%= @result.output %></pre>
      <p :if={@result[:reason]} id="console-reason" class="text-sm text-error break-words">
        {truncate(@result.reason)}
      </p>
    </div>
    """
  end

  defp console_result(%{state: {:rejected, reason}} = assigns) do
    assigns = assign(assigns, :message, rejection_message(reason))

    ~H"""
    <div id="console-result" role="alert" class="alert alert-error alert-soft">
      <.icon name="hero-no-symbol" class="size-5 shrink-0" />
      <span id="console-rejected" class="break-words">{@message}</span>
    </div>
    """
  end

  defp console_result(assigns), do: ~H""

  @doc "Vitals panel: telemetry cards, stale marker, chaos chamber and execution log."
  attr :vitals, :map, required: true
  attr :stale?, :boolean, default: false
  attr :chaos, :any, default: :idle
  attr :log, :any, required: true, doc: "the `@streams.log` stream"

  def vitals_panel(assigns) do
    ~H"""
    <section
      id="vitals-panel"
      class="card bg-base-100 border border-base-300 shadow-sm"
      aria-labelledby="vitals-title"
    >
      <div class="card-body gap-4">
        <h2 id="vitals-title" class="card-title flex items-center gap-2">
          <.icon name="hero-chart-bar" class="size-5 text-primary" /> BEAM vitals
          <span :if={@stale?} id="vitals-stale" class="badge badge-warning badge-sm">stale</span>
        </h2>

        <div id="vitals-cards" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          <.vital_card id="vital-workers" label="Active Workers" value={@vitals[:active_workers]} />
          <.vital_card
            id="vital-schedulers"
            label="Schedulers"
            value={@vitals[:schedulers_online]}
          />
          <.vital_card
            id="vital-dirty"
            label="Dirty CPU"
            value={@vitals[:dirty_cpu_schedulers_online]}
          />
          <.vital_card id="vital-runq" label="Run Queue" value={@vitals[:run_queue]} />
          <.vital_card id="vital-procs" label="Processes" value={@vitals[:process_count]} />
          <.vital_card
            id="vital-util"
            label="Utilization"
            value={utilization(@vitals[:utilization_percent])}
          />
          <.vital_card
            :for={key <- [:total, :processes, :binary, :ets, :code]}
            id={"vital-mem-#{key}"}
            label={memory_label(key)}
            value={memory(@vitals[:memory], key)}
          />
        </div>

        <.chaos_chamber chaos={@chaos} />

        <div>
          <h3 class="mb-2 flex items-center gap-2 font-semibold">
            <.icon name="hero-queue-list" class="size-4" /> Execution log
          </h3>
          <ul
            id="execution-log"
            phx-update="stream"
            class="max-h-72 divide-y divide-base-300 overflow-y-auto rounded-box border border-base-300"
          >
            <li
              id="execution-log-empty"
              class="hidden p-3 text-sm text-base-content/60 only:block"
            >
              No executions yet
            </li>
            <.log_entry :for={{dom_id, entry} <- @log} id={dom_id} entry={entry} />
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp memory_label(:total), do: "Total Mem"
  defp memory_label(:processes), do: "Process Mem"
  defp memory_label(:binary), do: "Binary Mem"
  defp memory_label(:ets), do: "ETS Mem"
  defp memory_label(:code), do: "Code Mem"
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp vital_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-box border border-base-300 bg-base-200/40 p-3 transition-colors hover:bg-base-200"
    >
      <div class="whitespace-nowrap text-xs uppercase tracking-wide text-base-content/60">
        {@label}
      </div>
      <div class="mt-1 whitespace-nowrap text-lg font-semibold tabular-nums">{@value || "n/a"}</div>
    </div>
    """
  end

  @doc "Chaos chamber: Inject Chaos button, help text and the last result."
  attr :chaos, :any, default: :idle

  def chaos_chamber(assigns) do
    assigns = assign(assigns, :running?, assigns.chaos == :running)

    ~H"""
    <div id="chaos-chamber" class="rounded-box border border-warning/40 bg-warning/5 p-4 space-y-3">
      <div class="flex items-center justify-between gap-3">
        <h3 class="flex items-center gap-2 font-semibold">
          <.icon name="hero-fire" class="size-4 text-warning" /> Chaos chamber
        </h3>
        <button
          type="button"
          id="inject-chaos"
          class="btn btn-warning btn-sm"
          phx-click="inject_chaos"
          disabled={@running?}
        >
          <.icon name="hero-bolt" class="size-4" /> Inject Chaos
        </button>
      </div>
      <p class="text-xs text-base-content/70">
        Runs an infinite loop in an isolated Worker. A Worker abandoned at the deadline can keep
        consuming a dirty scheduler until its fuel budget is exhausted. The fuel budget and the
        chaos gate (one run at a time, with a cooldown) bound that cost.
      </p>
      <span :if={@running?} id="chaos-running" class="flex items-center gap-2 text-sm">
        <span class="loading loading-spinner loading-sm"></span> Chaos running
      </span>
      <.chaos_result chaos={@chaos} />
    </div>
    """
  end

  attr :chaos, :any, required: true

  defp chaos_result(%{chaos: {:done, %{outcome: :contained} = result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div id="chaos-result" class="space-y-1 text-sm">
      <div class="flex flex-wrap items-center gap-2">
        <span class="badge badge-success">contained</span>
        <span id="chaos-kind">{kind_text(@result[:kind])}</span>
        <span id="chaos-wall-time" class="text-base-content/70">
          Wall time: {Format.duration(@result.wall_us)}
        </span>
      </div>
      <p id="chaos-liveview">
        {if @result[:same_process?],
          do: "LiveView process unchanged",
          else: "LiveView process changed"}
      </p>
    </div>
    """
  end

  defp chaos_result(%{chaos: {:done, result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div id="chaos-result" class="space-y-1 text-sm">
      <div class="flex flex-wrap items-center gap-2">
        <span class="badge badge-error">unexpected outcome</span>
        <span id="chaos-wall-time" class="text-base-content/70">
          Wall time: {Format.duration(@result[:wall_us] || 0)}
        </span>
      </div>
      <p id="chaos-reason" class="break-words">
        {truncate(@result[:reason] || kind_text(@result[:kind]))}
      </p>
    </div>
    """
  end

  defp chaos_result(%{chaos: {:rejected, reason}} = assigns) do
    assigns = assign(assigns, :message, chaos_rejection(reason))

    ~H"""
    <div id="chaos-result" role="alert" class="alert alert-warning alert-soft text-sm">
      <.icon name="hero-no-symbol" class="size-4 shrink-0" />
      <span id="chaos-rejected" class="break-words">{@message}</span>
    </div>
    """
  end

  defp chaos_result(assigns), do: ~H""

  @doc "One Execution_Log entry. `entry` is an Execution event payload."
  attr :id, :string, required: true
  attr :entry, :map, required: true

  def log_entry(assigns) do
    ~H"""
    <li id={@id} class="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
      <span class={["badge badge-sm", status_class(@entry.status)]}>{@entry.status}</span>
      <span class="badge badge-ghost badge-sm">{@entry.run_mode}</span>
      <span class="font-mono text-xs text-base-content/70">{short_id(@entry.plugin_id)}</span>
      <span :if={@entry.duration_ms} class="tabular-nums">{@entry.duration_ms} ms</span>
      <span :if={@entry.error_reason} class="truncate text-error" title={@entry.error_reason}>
        {@entry.error_reason}
      </span>
      <time class="ml-auto text-xs text-base-content/60">{time_text(@entry.inserted_at)}</time>
    </li>
    """
  end

  # Helpers

  defp chaos_plugin_name, do: @chaos_plugin_name

  defp plugin_options(%{ok?: true, result: options}) when is_list(options), do: options
  defp plugin_options(options) when is_list(options), do: options
  defp plugin_options(_), do: []

  defp state_class(:active), do: "badge-success"
  defp state_class(:quarantined), do: "badge-error"
  defp state_class(:compiling), do: "badge-info"
  defp state_class(_), do: "badge-ghost"

  defp status_class(status) when status in [:success, "success"], do: "badge-success"
  defp status_class(status) when status in [:timeout, "timeout"], do: "badge-warning"
  defp status_class(_), do: "badge-error"

  defp rejection_message(:busy), do: "busy"
  defp rejection_message(:plugin_not_active), do: "plugin_not_active"
  defp rejection_message({:error, message}) when is_binary(message), do: truncate(message)
  defp rejection_message(other), do: truncate(other)

  defp chaos_rejection(:in_flight), do: "chaos already running"
  defp chaos_rejection({:cooldown, ms}), do: "cooldown: #{ms} ms remaining"
  defp chaos_rejection(:fuel_not_configured), do: "fuel budget not configured"
  defp chaos_rejection({:plugin_state, state}), do: "chaos-chamber plugin is #{state}"
  defp chaos_rejection(:busy), do: "busy"
  defp chaos_rejection(other), do: truncate(other)

  defp kind_text({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_text(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp kind_text(kind) when is_binary(kind), do: kind
  defp kind_text(_), do: "error"

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, @max_reason)
  defp truncate(other), do: other |> inspect() |> truncate()

  defp utilization(nil), do: nil

  defp utilization(percent) when is_number(percent),
    do: "#{:erlang.float_to_binary(percent * 1.0, decimals: 1)}%"

  defp memory(%{} = memory, key) do
    case Map.get(memory, key) do
      bytes when is_integer(bytes) and bytes >= 0 -> Format.bytes(bytes)
      _ -> nil
    end
  end

  defp memory(_, _), do: nil

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: to_string(id)

  defp time_text(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp time_text(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp time_text(_), do: ""
end
