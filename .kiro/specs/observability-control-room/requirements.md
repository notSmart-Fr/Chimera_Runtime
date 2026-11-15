# Requirements Document

## Introduction

Phase 2 of ChimeraRuntime, "Observability Control Room & Agentic Orchestration", builds on the Phase 1 Poltergeist Sandbox (`.kiro/specs/poltergeist-sandbox/`). Phase 1 stores WebAssembly plugins in the `ChimeraRuntime.Sandbox` Ash domain and runs them through `ChimeraRuntime.Runner.Engine` inside isolated, deadline-bound, fuel-metered Wasmex workers (WASI disabled). Phase 2 adds three capabilities on top of it:

1. A Phoenix LiveView control room, `ChimeraRuntimeWeb.DashboardLive`, with three panels: a Plugin Registry and Health Scorecard (Cinder table), an Interactive Sandbox Console, and a BEAM Vitals and Chaos Chamber panel. The control room updates live from Phoenix PubSub events published when Executions and Plugins change.
2. A saga, `ChimeraRuntime.Orchestration.PublishPluginReactor`, built with Ash.Reactor, that publishes a Plugin: `:draft` to `:compiling`, one Gravedigger verification run through the Engine, then `:active`, with compensation to `:quarantined` on any failure after the compile transition.
3. A native Model Context Protocol (MCP) server, exposed from the `ChimeraRuntime.Sandbox` domain through `ash_ai`, so Kiro Crew agents can list Plugins, inspect execution metrics, run a Plugin, and quarantine a Plugin.

### Dependency and Platform Status (requires user approval)

The files `mix.exs`, `mix.lock`, and `deps/` were inspected. Per the workspace rule, no dependency may be added, removed, or altered without explicit user approval.

- Already present and sufficient: `ash` 3.37.4 (includes `Ash.Reactor` under `deps/ash/lib/ash/reactor`, and `Ash.Notifier.PubSub`), `reactor` 1.0.7, `cinder` 0.18.1 (supports aggregate and calculation fields and `Cinder.Refresh.refresh_table/3` with `silent: true`), `phoenix_live_view` 1.2.13, `phoenix` and `plug` (provide PubSub, `Plug.BasicAuth`-style comparisons, and `Plug.Crypto`), `daisyui` (Tailwind plugin, already imported in `assets/css/app.css`), `lazy_html` (test only), `stream_data`, and `wasmex` 0.16.0.
- `ash_ai` is NOT present in `mix.exs` or `deps/`. The user has APPROVED adding exactly `ash_ai` with an exact pinned version (`"== x.y.z"`) during implementation. At the time of writing, Hex lists `ash_ai` 1.5.4, which requires `ash ~> 3.33 and >= 3.33.6` (satisfied by 3.37.4), `ash_json_api >= 1.4.27`, `open_api_spex ~> 3.0`, and `telemetry ~> 1.1`. None of `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case` is in `deps/`. They arrive only as transitive Hex dependencies of `ash_ai` in `mix.lock`, never as `mix.exs` entries.
- `ash_ai` serves MCP through the Plug-based `AshAi.Mcp.Router`. No separate MCP transport dependency is needed. `req_llm` is optional in `ash_ai` and is not needed for MCP-only use.
- Lockfile scope: `mix.exs` receives exactly one new line (`ash_ai` with an exact `"== x.y.z"` pin). `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case` are added to `mix.lock` only. The implementation records the `mix.lock` diff and stops to ask if resolution would change any existing locked version, add any package beyond the six approved `mix.lock` entries, or need any additional `mix.exs` line.
- RESOLVED FINDING (user decision): the Hex metadata checked while writing this spec shows that `ash_json_api` (latest 1.8.0) has a hard dependency on `json_xema ~> 0.4`, which in turn requires `xema ~> 0.16` and `conv_case ~> 0.2`. None of these three packages was in `mix.lock`. The user APPROVED all six `mix.lock`-only additions that resolving `ash_ai` is expected to produce: `ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case`. The only `mix.exs` change remains the single `ash_ai` exact-pin line. No further approval is needed for these six entries.
- Approval covers the `ash_ai` line in `mix.exs` and the six `mix.lock` entries named above. Any other new package, any change that would raise or lower the locked version of an existing dependency, and any additional `mix.exs` line require separate explicit approval and the implementation must stop and ask.
- `Ash.Reactor`'s `ash_update` step passes a `changeset` argument to its undo action, and the Phase 1 `:quarantine` action does not declare that argument. The Publish_Saga therefore uses a custom `Reactor.Step` for the compile transition so that Phase 1 resource actions stay unchanged (see Requirement 16).
- After adding `ash_ai`, `mix usage_rules.sync --yes` is run so the Ash and Phoenix skills stay up to date.

### Demo Exposure Posture (user decision)

The user decided that `/control-room` stays OPEN with no authentication, so that hackathon judges can use the live demo immediately. This is a documented risk: any visitor can run active Plugins and trigger chaos runs. The Run_Capacity_Guard and the Chaos_Gate bound the load. The `/mcp` endpoint is NOT open: it keeps its token, Origin, and body-size checks (Requirement 15). The posture is isolated in one named router pipeline so that it is easy to change later (Requirement 1, criteria 10 to 15).

## Glossary

- **Demo_Exposure_Note**: The documented statement of the unauthenticated posture of the Control_Room and its risks, defined in Requirement 1.
- **Control_Room_Access_Pipeline**: The router pipeline `:control_room_access` through which `/control-room` is routed, containing no authentication plug in Phase 2.
- **Control_Room**: The LiveView module `ChimeraRuntimeWeb.DashboardLive`, mounted at the route `/control-room`.
- **Registry_Panel**: The Control_Room panel that shows Plugins and their health aggregates in a Cinder table.
- **Console_Panel**: The Control_Room panel in which an operator runs an active Plugin.
- **Vitals_Panel**: The Control_Room panel that shows BEAM telemetry and hosts the Chaos_Chamber.
- **Chaos_Chamber**: The part of the Vitals_Panel containing the "Inject Chaos" button and its result display.
- **Chaos_Plugin**: The persisted Plugin named `chaos-chamber` that holds an infinite-loop Wasm module and a `timeout_ms` equal to the Chaos_Deadline.
- **Chaos_Deadline**: The `timeout_ms` of the Chaos_Plugin, an integer from 10 to 1000 milliseconds, default 250, set by `config :chimera_runtime, :chaos, deadline_ms: n`.
- **Chaos_Gate**: The process-safe rate limiter that permits at most one in-flight chaos run and enforces a cooldown of 2000 milliseconds (configurable) between the end of one chaos run and the start of the next, across all Control_Room sessions.
- **Engine**: The module `ChimeraRuntime.Runner.Engine` defined in Phase 1.
- **Sandbox_Domain**: The Ash domain `ChimeraRuntime.Sandbox`, which registers Plugin, Execution, and `Execution.Version`.
- **Task_Supervisor**: The `Task.Supervisor` named `ChimeraRuntime.Runner.TaskSupervisor`.
- **Fuel_Budget**: The finite Wasmtime fuel set per run, from `config :chimera_runtime, ChimeraRuntime.Runner.Engine, fuel_budget: n`.
- **Args_Codec**: The pure module that parses an operator-supplied JSON text into an Engine argument list and prints an argument list back to JSON text.
- **Wall_Time**: The elapsed time of one `Engine.run/4` call as measured in the calling process with the monotonic clock in native units, converted to whole microseconds.
- **Run_Capacity_Guard**: The check that rejects a new run with `{:error, :busy}` when the number of active Workers under the Task_Supervisor is at or above the configured `max_workers` (default 8).
- **Execution_Event**: The PubSub event `"execution_recorded"` published on the topic `"sandbox:executions"` after an Execution is created.
- **Plugin_Event**: The PubSub event `"plugin_changed"` published on the topic `"sandbox:plugins"` after a Plugin is created, updated, compiled, activated, or quarantined.
- **Event_Payload**: The map carried by an Execution_Event or Plugin_Event, defined in Requirement 5.
- **Execution_Log**: The bounded list of recent Execution_Events displayed in the Control_Room.
- **Publish_Saga**: The module `ChimeraRuntime.Orchestration.PublishPluginReactor`, an Ash.Reactor that publishes a Plugin.
- **Saga_Step**: One named step of the Publish_Saga: `:load_plugin`, `:begin_compile`, `:verify`, `:promote`.
- **Compensation**: The undo of `:begin_compile` that transitions the Plugin to `:quarantined`.
- **Saga_Result**: The value returned by `ChimeraRuntime.Orchestration.PublishPluginReactor.publish/3`, defined in Requirement 13.
- **Gravedigger**: The Phase 1 one-shot verification flow: an Engine run with `run_mode: :verification` on a Plugin in `:compiling` whose `verification_used` is false.
- **MCP_Server**: The Model Context Protocol endpoint served by `AshAi.Mcp.Router` and mounted at `/mcp`.
- **MCP_Tool**: One of the four tools declared in the `tools` section of the Sandbox_Domain: `list_plugins`, `inspect_execution_metrics`, `run_plugin`, `quarantine_plugin`.
- **MCP_Guard**: The Plug `ChimeraRuntimeWeb.Plugs.McpGuard` that authenticates and filters requests before they reach the MCP_Server.
- **Loopback_Request**: A request whose `conn.remote_ip` is `127.0.0.1` or `::1`.
- **Lifecycle_State**: One of `:draft`, `:compiling`, `:active`, `:quarantined` (Phase 1).
- **Execution_Status**: One of `:success`, `:timeout`, `:error` (Phase 1).
- **Test_Suite**: The ExUnit, ExUnitProperties (StreamData), and Phoenix.LiveViewTest tests for Phase 2.

## Requirements

### Requirement 1: Control Room Route and Shell

**User Story:** As an operator, I want one LiveView page that shows registry health, a run console, and BEAM vitals, so that I can observe and exercise the sandbox from a single place.

#### Acceptance Criteria

1. THE Control_Room SHALL be the module `ChimeraRuntimeWeb.DashboardLive`, routed with `live "/control-room", DashboardLive` inside a router scope that uses the `:browser` pipeline.
2. THE Control_Room SHALL render three panels in this order: Registry_Panel, Console_Panel, and Vitals_Panel.
3. THE Control_Room template SHALL begin with `<Layouts.app flash={@flash} ...>` and SHALL render every form field through the imported `<.input>` component and every icon through the imported `<.icon>` component.
4. THE Control_Room SHALL style its panels with Tailwind CSS classes and the DaisyUI classes provided by the installed `daisyui` plugin, and SHALL define any custom CSS as plain rules in `assets/css/app.css` without `@apply`.
5. THE Control_Room SHALL contain no inline `<script>` tag, and SHALL load no external script `src` or stylesheet `href`.
6. THE Control_Room SHALL use the Cinder theme configured in `config/config.exs` (`default_theme: "daisy_ui"`) for its table.
7. WHEN the Control_Room is mounted over a connected socket, THE Control_Room SHALL subscribe the LiveView process to the topics `"sandbox:executions"` and `"sandbox:plugins"` on `ChimeraRuntime.PubSub`.
8. WHILE the Control_Room is rendered over the static (disconnected) HTTP request, THE Control_Room SHALL render all three panels without subscribing to PubSub and without starting the vitals timer.
9. THE Control_Room SHALL remain outside the existing `Phoenix.LiveDashboard` route at `/dev/dashboard`.
10. THE Control_Room route SHALL be intentionally unauthenticated in Phase 2, so that hackathon judges can open the live demo immediately, and THE Control_Room SHALL require no Basic Auth, token, or session credential.
11. THE router SHALL route `/control-room` through a dedicated named pipeline `:control_room_access` that contains no authentication plug in Phase 2, so that adding authentication later requires changing only that pipeline.
12. THE Control_Room SHALL display a visible banner with the text "Demo mode: open access" so that every visitor sees the unauthenticated posture.
13. THE Demo_Exposure_Note SHALL be recorded in the `@moduledoc` of `ChimeraRuntimeWeb.DashboardLive`, in a router comment above the `/control-room` route, and in the design document, and SHALL state that any visitor can run active Plugins through the Console_Panel, can trigger the Chaos_Chamber, and can read Plugin names and health aggregates.
14. THE Demo_Exposure_Note SHALL name the Run_Capacity_Guard (Requirement 9) and the Chaos_Gate (Requirement 8) as the safeguards that bound the cost of unauthenticated use, and SHALL state that these safeguards limit load but do not provide confidentiality or access control.
15. THE Control_Room SHALL expose neither `wasm_binary` nor `source_code` (Requirement 2, criterion 5) and SHALL offer no action that creates, edits, destroys, or quarantines a Plugin other than the Chaos_Plugin bootstrap of Requirement 8, so that the unauthenticated surface stays limited to running active Plugins and chaos injection.

### Requirement 2: Plugin Registry and Health Scorecard

**User Story:** As an operator, I want a sortable, filterable table of plugins with run statistics, so that I can find unreliable plugins quickly.

#### Acceptance Criteria

1. THE Registry_Panel SHALL render a `Cinder.collection` over the Plugin resource with the DOM id `plugin-registry`.
2. THE Registry_Panel SHALL display one row per Plugin with the columns `name`, `state`, `timeout_ms`, `total_runs`, `failure_rate`, and `avg_duration_ms`.
3. THE Registry_Panel SHALL enable sorting on `name`, `state`, `total_runs`, `failure_rate`, and `avg_duration_ms`, and filtering on `name` and `state`.
4. THE Registry_Panel SHALL display `failure_rate` as a percentage with one decimal place, `total_runs` as an integer, and `avg_duration_ms` with up to three decimal places, or the text "n/a" WHEN `avg_duration_ms` is nil.
5. THE Registry_Panel SHALL NOT select, load, or render the `wasm_binary` or `source_code` attributes of any Plugin.
6. WHEN a Plugin has zero Executions, THE Registry_Panel SHALL display `total_runs` as 0, `failure_rate` as 0.0%, and `avg_duration_ms` as "n/a".
7. THE Registry_Panel SHALL display the Plugin named `chaos-chamber` with a visible "system" badge.
8. WHEN the Plugin table contains no rows, THE Registry_Panel SHALL render the Cinder `:empty` slot with the text "No plugins yet".
9. IF the Plugin query fails (including a SQLite "database is locked" error), THEN THE Registry_Panel SHALL render the Cinder `:error` slot, SHALL keep the Control_Room process alive, and SHALL retry on the next scheduled or event-driven refresh.

### Requirement 3: Console Argument Codec

**User Story:** As an operator, I want my JSON arguments validated and echoed back exactly, so that malformed input never reaches the Engine.

#### Acceptance Criteria

1. THE Args_Codec SHALL expose a parse function that accepts a text and returns `{:ok, args}` or `{:error, reason}`, where `args` is a list of 0 to 64 numbers.
2. WHEN the text is a JSON array of 0 to 64 elements, each of which is a JSON integer or JSON number, THE Args_Codec SHALL return `{:ok, args}` with the elements in the original order, integers as Elixir integers and other numbers as Elixir floats.
3. WHEN the text is empty or contains only whitespace, THE Args_Codec SHALL return `{:ok, []}`.
4. IF the text is larger than 4096 bytes, THEN THE Args_Codec SHALL return `{:error, :too_large}` without decoding the text.
5. IF the text is not valid JSON, THEN THE Args_Codec SHALL return `{:error, :invalid_json}`.
6. IF the text is valid JSON but is not an array, or the array holds more than 64 elements, or any element is not a number (including strings, booleans, null, arrays, and objects), THEN THE Args_Codec SHALL return `{:error, reason}` where `reason` identifies the offending shape.
7. THE Args_Codec SHALL decode JSON without creating atoms.
8. THE Args_Codec SHALL expose a print function that converts a list of numbers into a JSON array text.
9. FOR ALL lists of 0 to 64 finite numbers, parsing the printed text SHALL produce a list equal to the original list (round-trip property).
10. FOR ALL texts, THE Args_Codec parse function SHALL return exactly one of `{:ok, list}` or `{:error, reason}` and SHALL raise nothing.

### Requirement 4: Interactive Sandbox Console

**User Story:** As an operator, I want to pick an active plugin, enter arguments, run it, and see the output and the time it took, so that I can test plugins interactively.

#### Acceptance Criteria

1. THE Console_Panel SHALL offer a plugin selector populated with the Plugins whose Lifecycle_State is `:active`, excluding the Chaos_Plugin, a text input for the exported function name, a text area for the JSON arguments, and a "Run" button.
2. WHEN an operator submits the Console_Panel form, THE Control_Room SHALL parse the arguments with the Args_Codec, and IF parsing fails, THEN THE Control_Room SHALL display the parse error next to the argument field and SHALL NOT call the Engine.
3. WHEN an operator submits a valid Console_Panel form, THE Control_Room SHALL re-read the selected Plugin from the Sandbox_Domain, and SHALL call `Engine.run/4` with `run_mode: :standard` from a process started with `Phoenix.LiveView.start_async/3`, so that the LiveView process never executes `Engine.run/4` itself.
4. WHILE a console run is in flight, THE Console_Panel SHALL disable the "Run" button and SHALL display a running indicator.
5. WHEN the Engine returns `{:ok, output}`, THE Console_Panel SHALL display the output as JSON text, the status "success", and the Wall_Time.
6. WHEN the Engine returns `{:error, reason}`, THE Console_Panel SHALL display the status "error" or "timeout" (`:timeout` and `:fuel_exhausted` reasons map to "timeout"), a readable reason of at most 300 characters, and the Wall_Time.
7. THE Console_Panel SHALL display the Wall_Time in microseconds WHEN the Wall_Time is below 1000 microseconds (for example "412 µs"), and in milliseconds with exactly three decimal places otherwise (for example "12.345 ms").
8. FOR ALL non-negative integer Wall_Time values, parsing the displayed duration text back to microseconds SHALL return the original value (round-trip property).
9. THE Console_Panel SHALL state that the persisted Execution `duration_ms` is a whole number of milliseconds and that the Wall_Time additionally includes Execution persistence.
10. IF the Run_Capacity_Guard rejects the run, THEN THE Console_Panel SHALL display "busy" and SHALL NOT call the Engine.
11. IF the start_async process exits abnormally, THEN THE Control_Room SHALL display an error message, SHALL clear the in-flight indicator, and SHALL keep the LiveView process and socket alive.
12. IF the selected Plugin is no longer `:active` at submit time, THEN THE Console_Panel SHALL display the Engine error `:plugin_not_active` and SHALL refresh the plugin selector.
13. THE Console_Panel SHALL accept only the `:standard` Run_Mode, and SHALL NOT offer the `:verification` Run_Mode.

### Requirement 5: Execution and Plugin Event Publication

**User Story:** As a developer, I want state changes published on PubSub with a stable contract, so that dashboards and other subscribers update without polling.

#### Acceptance Criteria

1. WHEN an Execution is created through the Sandbox_Domain, THE Sandbox_Domain SHALL broadcast an Execution_Event on the topic `"sandbox:executions"` with the event name `"execution_recorded"`, after the creating action has committed.
2. THE Execution_Event Event_Payload SHALL be a map with exactly the keys `id`, `plugin_id`, `status`, `run_mode`, `duration_ms`, `error_reason`, and `inserted_at`, where `error_reason` is nil or truncated to at most 200 characters.
3. THE Execution_Event Event_Payload SHALL NOT contain the `input_json` or `output_json` values of the Execution.
4. WHEN a Plugin is created, updated, compiled, activated, or quarantined through the Sandbox_Domain, THE Sandbox_Domain SHALL broadcast a Plugin_Event on the topic `"sandbox:plugins"` with the event name `"plugin_changed"`, after the action has committed.
5. THE Plugin_Event Event_Payload SHALL be a map with exactly the keys `id`, `name`, `state`, `action`, and `updated_at`, and SHALL NOT contain `wasm_binary` or `source_code`.
6. THE Sandbox_Domain SHALL NOT broadcast a Plugin_Event for the internal `:mark_verification_used` action.
7. THE broadcasts SHALL be delivered through `ChimeraRuntime.PubSub` as `%Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}` messages.
8. THE publication SHALL be declared with the `Ash.Notifier.PubSub` notifier on the Execution and Plugin resources, SHALL NOT change the Engine source, and SHALL NOT change the Engine return contract or totality (Phase 1 Requirements 9 and 10).
9. IF publishing a broadcast raises or fails, THEN THE Engine SHALL still return its run result unchanged, and the failure SHALL be logged by the existing Phase 1 persistence-failure path (Phase 1 Requirement 9, criterion 6).
10. WHEN an Execution create is rejected by validation or a Plugin action fails, THE Sandbox_Domain SHALL broadcast no event for that action.
11. FOR ALL Executions, the payload builder SHALL produce a map with the key set of criterion 2 and with `error_reason` of at most 200 characters.
12. FOR ALL Plugins, the payload builder SHALL produce a map with the key set of criterion 5.

### Requirement 6: Live Updates in the Control Room

**User Story:** As an operator, I want the registry table and execution log to update as runs happen, so that I see activity from the console, chaos runs, the saga, and MCP agents without reloading.

#### Acceptance Criteria

1. WHEN the Control_Room receives an Execution_Event, THE Control_Room SHALL insert a log entry at the head of the Execution_Log using a LiveView stream limited to the 50 most recent entries.
2. THE Execution_Log entry SHALL display the plugin id, status, run mode, duration in milliseconds, and the truncated `error_reason` when present, and SHALL be built from the Event_Payload without a database read.
3. WHEN the Control_Room receives an Execution_Event or a Plugin_Event, THE Control_Room SHALL schedule one silent refresh of the `plugin-registry` Cinder table (`Cinder.Refresh.refresh_table/3` with `silent: true`) to run 250 milliseconds later, unless a refresh is already scheduled.
4. WHEN N events arrive within one 250 millisecond coalescing window, THE Control_Room SHALL perform at most one registry refresh for that window.
5. WHEN a Plugin_Event arrives, THE Control_Room SHALL also refresh the console plugin selector in the same coalesced step.
6. WHILE the Control_Room is connected, THE Control_Room SHALL refresh the registry every 30 seconds as a fallback for lost events.
7. IF the Control_Room receives a broadcast message whose topic, event, or payload does not match the contract of Requirement 5, THEN THE Control_Room SHALL ignore the message and SHALL keep the LiveView process alive.
8. WHEN the Control_Room terminates, THE Control_Room SHALL leave no timer or subscription behind (process termination releases the PubSub subscription and the timers).

### Requirement 7: BEAM Vitals

**User Story:** As an operator, I want live BEAM telemetry, so that I can see worker load and memory while plugins run.

#### Acceptance Criteria

1. WHILE the Control_Room is connected, THE Vitals_Panel SHALL refresh its telemetry every 1000 milliseconds with a timer started in the LiveView process.
2. THE Vitals_Panel SHALL display the number of active Workers, computed from `Supervisor.count_children/1` on the Task_Supervisor.
3. THE Vitals_Panel SHALL display BEAM memory in bytes formatted as human-readable units for `total`, `processes`, `binary`, `ets`, and `code`, taken from `:erlang.memory/0`.
4. THE Vitals_Panel SHALL display the number of online schedulers, the number of online dirty CPU schedulers, the total run queue length, the process count, and the average scheduler utilization between two consecutive samples as a percentage from 0.0 to 100.0.
5. THE telemetry collection SHALL be a pure function of the values read from the VM, SHALL raise nothing, and SHALL return a map with a fixed key set.
6. FOR ALL non-negative integer byte counts, THE byte formatter SHALL return a non-empty string whose numeric part is less than 1024 WHEN the unit is not the largest unit.
7. IF a telemetry read fails, THEN THE Vitals_Panel SHALL keep the last successful values, SHALL display a "stale" marker, and SHALL keep the LiveView process alive.
8. WHILE a chaos run or console run is in flight, THE Vitals_Panel SHALL continue to refresh at the 1000 millisecond interval.

### Requirement 8: Chaos Chamber

**User Story:** As a platform engineer, I want an "Inject Chaos" button that runs an infinite loop, so that I can demonstrate fault isolation without the LiveView socket dropping.

#### Acceptance Criteria

1. THE Chaos_Chamber SHALL contain an "Inject Chaos" button.
2. THE Chaos_Plugin SHALL be a persisted Plugin with the name `chaos-chamber`, `timeout_ms` equal to the Chaos_Deadline, and a `wasm_binary` holding a hand-assembled module that exports `run() -> ()` and loops forever, stored as a byte literal in `lib/` (not in `test/support`).
3. WHEN the "Inject Chaos" button is clicked and the Chaos_Plugin does not exist, THE Control_Room SHALL create the Chaos_Plugin through the Sandbox_Domain, compile it, and activate it without running the Gravedigger.
4. WHEN the "Inject Chaos" button is clicked, THE Control_Room SHALL acquire the Chaos_Gate, and WHEN the Chaos_Gate is acquired, THE Control_Room SHALL call `Engine.run/4` on the Chaos_Plugin with the function name `"run"`, an empty argument list, and `run_mode: :standard` from a `start_async` process.
5. IF the Chaos_Gate reports an in-flight chaos run, THEN THE Chaos_Chamber SHALL display "chaos already running" and SHALL NOT call the Engine.
6. IF the Chaos_Gate reports that the cooldown has not elapsed, THEN THE Chaos_Chamber SHALL display the remaining cooldown in whole milliseconds and SHALL NOT call the Engine.
7. IF the configured Fuel_Budget is not a positive integer, THEN THE Chaos_Chamber SHALL refuse to run, SHALL display "fuel budget not configured", and SHALL NOT call the Engine.
8. IF the Chaos_Plugin exists in a Lifecycle_State other than `:active`, THEN THE Chaos_Chamber SHALL display the current state, SHALL NOT call the Engine, and SHALL NOT modify the Chaos_Plugin.
9. WHEN the chaos run returns `{:error, :timeout}` or `{:error, {:fuel_exhausted, _}}`, THE Chaos_Chamber SHALL display "contained", the error kind, the Wall_Time, and the text "LiveView process unchanged" computed from the comparison of the LiveView `self()` before and after the run.
10. WHEN the chaos run returns any other result, THE Chaos_Chamber SHALL display the result as an unexpected outcome with its reason.
11. THE Control_Room socket SHALL remain connected and the LiveView process SHALL remain the same process before, during, and after a chaos run.
12. WHEN the chaos run ends, THE Chaos_Gate SHALL release the in-flight slot and SHALL start the cooldown, including WHEN the run ends abnormally or the starting LiveView process has terminated.
13. THE Chaos_Chamber SHALL document, in its displayed help text, that a Worker abandoned at the deadline can keep consuming a dirty scheduler until the Fuel_Budget is exhausted, and that the Fuel_Budget and the Chaos_Gate bound that cost.
14. FOR ALL sequences of chaos requests at monotonically non-decreasing times, THE Chaos_Gate decision function SHALL never allow two overlapping in-flight runs and SHALL never allow a start earlier than the cooldown after the previous end.

### Requirement 9: Shared Run Safeguards

**User Story:** As a platform engineer, I want bounded concurrency and tolerance of SQLite contention, so that the control room and agents cannot overload the sandbox.

#### Acceptance Criteria

1. THE Run_Capacity_Guard SHALL return `:ok` WHEN the number of active Workers under the Task_Supervisor is below `max_workers`, and `{:error, :busy}` otherwise, with `max_workers` read from `config :chimera_runtime, ChimeraRuntime.RunGuard, max_workers: 8`.
2. THE Console_Panel, the MCP_Tool `run_plugin`, and the Chaos_Chamber SHALL each invoke the Run_Capacity_Guard before calling the Engine.
3. THE Run_Capacity_Guard SHALL treat the check as a soft limit and SHALL NOT hold a lock across the Engine call.
4. THE Control_Room SHALL run every `Engine.run/4` call and every Sandbox_Domain write in a process other than the LiveView process.
5. WHEN several Executions are persisted concurrently, THE Control_Room SHALL tolerate "database is locked" errors by displaying the Cinder error state or a retry message and SHALL NOT crash the LiveView process.
6. THE Control_Room SHALL NOT issue one registry query per event, and SHALL use the coalescing of Requirement 6.
7. THE SQLite Repo configuration SHALL set `busy_timeout` to at least 5000 milliseconds in the dev and prod environments, and the implementation SHALL verify the effective value in `config/dev.exs` and `config/runtime.exs`.
8. THE implementation SHALL keep the SQLite journal mode that Phase 1 uses (WAL, as shown by the existing `-wal` files).

### Requirement 10: Publish Saga Structure and Success Path

**User Story:** As a platform engineer, I want a saga that promotes a plugin only after a verification run succeeds, so that unverified code never becomes active.

#### Acceptance Criteria

1. THE Publish_Saga SHALL be the module `ChimeraRuntime.Orchestration.PublishPluginReactor`, defined with `use Ash.Reactor` and `default_domain ChimeraRuntime.Sandbox`.
2. THE Publish_Saga SHALL declare the inputs `plugin_id` (a UUID), `function_name` (a binary of 1 to 255 bytes), and `args` (a list of 0 to 64 elements, default `[]`).
3. THE Publish_Saga SHALL declare exactly four steps in dependency order: `:load_plugin`, `:begin_compile`, `:verify`, `:promote`.
4. THE Publish_Saga SHALL run every step with `async?: false`, so that SQLite writes happen one at a time and compensation order is deterministic.
5. WHEN `:load_plugin` runs, THE Publish_Saga SHALL read the Plugin fresh from the Sandbox_Domain by `plugin_id`.
6. WHEN `:begin_compile` runs, THE Publish_Saga SHALL transition the Plugin from `:draft` to `:compiling` through the Sandbox_Domain `compile_plugin` interface.
7. WHEN `:verify` runs, THE Publish_Saga SHALL re-read the Plugin from the Sandbox_Domain and SHALL call `Engine.run(plugin, function_name, args, run_mode: :verification)`.
8. WHEN `:verify` receives `{:ok, output}` from the Engine, THE Publish_Saga SHALL pass `output` to `:promote`.
9. WHEN `:promote` runs, THE Publish_Saga SHALL transition the Plugin from `:compiling` to `:active` through the Sandbox_Domain `activate_plugin` interface.
10. WHEN all four steps succeed, THE Publish_Saga SHALL return `{:ok, %{plugin: plugin, verification: %{output: output}}}` where `plugin` has the Lifecycle_State `:active`.
11. THE Publish_Saga SHALL treat any `{:ok, _}` result of the Gravedigger run as success, independent of the returned values.
12. THE Publish_Saga SHALL be invoked through `ChimeraRuntime.Orchestration.PublishPluginReactor.publish(plugin_id, function_name, args)` which wraps `Reactor.run/4` and returns the Saga_Result of Requirement 13.
13. THE Publish_Saga SHALL be a code-level API only, and SHALL NOT be exposed as an MCP_Tool or as a Control_Room button in Phase 2.

### Requirement 11: Publish Saga Preflight and Failure Modes

**User Story:** As a platform engineer, I want bad requests rejected before any state change and runtime failures classified, so that only real plugin failures cause quarantine.

#### Acceptance Criteria

1. WHEN `:load_plugin` runs, THE Publish_Saga SHALL validate the inputs with `Engine.validate_input/4` (plugin, function name, args, `run_mode: :verification`), and IF validation fails, THEN THE Publish_Saga SHALL return an error with stage `:preflight` and reason `{:invalid_input, detail}` without changing the Plugin.
2. IF the Plugin does not exist, THEN THE Publish_Saga SHALL return an error with stage `:preflight` and reason `:not_found` without changing any record.
3. IF the Plugin Lifecycle_State is not `:draft`, THEN THE Publish_Saga SHALL return an error with stage `:preflight` and reason `{:invalid_state, state}` without changing the Plugin.
4. IF the `wasm_binary` of the Plugin is nil or has zero bytes, THEN THE Publish_Saga SHALL return an error with stage `:preflight` and reason `:missing_binary` before any transition, so that the Plugin remains `:draft`.
5. IF `verification_used` is true on a Plugin in `:draft`, THEN THE Publish_Saga SHALL return an error with stage `:preflight` and reason `:verification_already_used` without changing the Plugin.
6. IF `:begin_compile` fails, THEN THE Publish_Saga SHALL return an error with stage `:compile`, SHALL NOT quarantine the Plugin, and SHALL leave the Plugin in the state it had before the call.
7. IF the Engine returns `{:error, reason}` during `:verify` (including `:timeout`, `{:fuel_exhausted, _}`, `{:trap, _}`, `{:compile_error, _}`, `{:unsatisfied_import, _}`, `{:missing_export, _}`, `{:worker_exit, _}`, `:verification_already_used`, `:verification_marker_failed`, `:plugin_not_active`, `:missing_binary`, `:invalid_timeout`, and `{:runtime_failure, _}`), THEN THE Publish_Saga SHALL fail the step and SHALL run the Compensation.
8. IF `:promote` fails (for example because the Plugin is no longer `:compiling`), THEN THE Publish_Saga SHALL run the Compensation and return an error with stage `:promote`.
9. IF an unexpected raise, exit, or throw occurs in any step, THEN THE Publish_Saga SHALL convert it into an error result with the failing stage and SHALL NOT let the exception reach the caller of `publish/3`.
10. THE Publish_Saga SHALL NOT retry the Gravedigger run, because the Phase 1 one-shot is consumed when the Worker starts.
11. THE Publish_Saga SHALL apply the Engine deadline of the Plugin as the only time bound of the `:verify` step, and SHALL NOT impose a saga-wide timeout that could terminate the saga before the Compensation runs.

### Requirement 12: Publish Saga Compensation

**User Story:** As a platform engineer, I want a failed publish to leave the plugin quarantined, so that a plugin that failed verification cannot run.

#### Acceptance Criteria

1. THE `:begin_compile` step SHALL be a custom `Reactor.Step` module whose `undo/4` callback quarantines the Plugin, so that the Compensation runs only after `:begin_compile` has succeeded and a later step has failed.
2. WHEN the Compensation runs, THE Publish_Saga SHALL re-read the Plugin from the Sandbox_Domain and SHALL call the Sandbox_Domain `quarantine_plugin` interface on the fresh record.
3. WHEN the Compensation finds the Plugin already in `:quarantined`, THE Publish_Saga SHALL treat the Compensation as successful and SHALL NOT report an error.
4. WHEN the Compensation succeeds, THE Plugin SHALL have the Lifecycle_State `:quarantined`, and the Saga_Result SHALL report `compensation: :quarantined`.
5. IF the Compensation quarantine call fails with a transient database error (including SQLite "database is locked"), THEN THE `undo/4` callback SHALL return `:retry` and SHALL be retried by Reactor up to its undo retry limit.
6. IF the Compensation fails after all retries or fails with a non-transient error, THEN THE Publish_Saga SHALL log one error entry with the plugin id and the failure reason, SHALL return the original failure together with `compensation: {:failed, reason}`, and SHALL report the observed `plugin_state` (expected `:compiling`).
7. WHEN the Compensation has failed, THE Publish_Saga SHALL leave the Plugin untouched by further automatic action, so that an operator can quarantine the Plugin through the MCP_Tool `quarantine_plugin` or the Sandbox_Domain interface.
8. THE Publish_Saga SHALL NOT quarantine a Plugin on any failure that occurs before `:begin_compile` succeeds.
9. THE Publish_Saga SHALL NOT quarantine a Plugin that was already `:active` or `:quarantined` before the call.
10. THE Compensation SHALL NOT delete or modify Executions, and SHALL leave the Execution recorded by the failed Gravedigger run in place.
11. THE Compensation SHALL leave `verification_used` true after a Gravedigger run that consumed the one-shot.

### Requirement 13: Saga Result Contract and Concurrency

**User Story:** As a developer, I want a stable result shape and single-flight publishing per plugin, so that callers can pattern match and concurrent publishes cannot corrupt state.

#### Acceptance Criteria

1. WHEN `publish/3` succeeds, THE Publish_Saga SHALL return `{:ok, %{plugin: %Plugin{state: :active}, verification: %{output: list}}}`.
2. WHEN `publish/3` fails, THE Publish_Saga SHALL return `{:error, %{stage: stage, reason: reason, plugin_state: state, compensation: compensation}}` with `stage` one of `:lock`, `:preflight`, `:compile`, `:verify`, `:promote`, `state` one of `:draft`, `:compiling`, `:active`, `:quarantined`, `:unknown`, and `compensation` one of `:not_needed`, `:quarantined`, `{:failed, reason}`.
3. THE Publish_Saga SHALL determine `plugin_state` by reading the Plugin after the saga ends, and SHALL report `:unknown` IF that read fails.
4. THE Publish_Saga SHALL return exactly one tuple for every input, including inputs of an invalid type, and SHALL raise, exit, and throw nothing to the caller.
5. WHEN `publish/3` is called for a `plugin_id` for which another `publish/3` call is in progress on the same node, THE Publish_Saga SHALL return `{:error, %{stage: :lock, reason: :publish_in_progress, plugin_state: state, compensation: :not_needed}}` without calling any step, using `:global.trans/4` with a retry count of 0 or an equivalent non-blocking lock.
6. THE Publish_Saga SHALL release the per-Plugin lock WHEN the saga ends with any result.
7. WHEN `publish/3` fails at any stage, THE Publish_Saga SHALL preserve the `reason` term produced by the failing step, unwrapped from `Reactor.Error` wrappers.
8. FOR ALL Engine verification outcomes of the set listed in Requirement 11 criterion 7 plus `{:ok, output}`, THE Publish_Saga result SHALL satisfy: success implies `:active` and an Execution with `run_mode: :verification` exists; failure after a successful `:begin_compile` implies `:quarantined` WHEN the Compensation succeeds.
9. THE Publish_Saga SHALL accept a verification runner and a quarantine function through application configuration (`config :chimera_runtime, ChimeraRuntime.Orchestration, verification_runner: fun, quarantine_fun: fun`), defaulting to `&Engine.run/4` and the Sandbox_Domain `quarantine_plugin` interface, so that tests can inject failures.

### Requirement 14: MCP Tool Exposure

**User Story:** As a Kiro Crew agent, I want MCP tools to list plugins, inspect metrics, run a plugin, and quarantine a plugin, so that I can operate the sandbox without a browser.

#### Acceptance Criteria

1. THE Sandbox_Domain SHALL use the `AshAi` extension and SHALL declare exactly four tools in its `tools` section: `list_plugins`, `inspect_execution_metrics`, `run_plugin`, `quarantine_plugin`.
2. THE tool `list_plugins` SHALL expose the Plugin read action with `select` limited to `id`, `name`, `state`, `timeout_ms`, `inserted_at`, and `updated_at`, and `load` of `total_runs`, `failure_rate`, and `avg_duration_ms`, and SHALL NOT return `wasm_binary` or `source_code`.
3. THE tool `list_plugins` SHALL restrict `filterable_fields` to `id`, `name`, and `state`, and SHALL restrict `sortable_fields` to `name`, `state`, `total_runs`, `failure_rate`, and `avg_duration_ms`, and SHALL accept a `limit` of at most 100 results per call.
4. THE tool `inspect_execution_metrics` SHALL return, for one Plugin identified by `id` (UUID), the fields `id`, `name`, `state`, `total_runs`, `failure_rate`, and `avg_duration_ms`.
5. THE tool `run_plugin` SHALL be backed by a new generic action `:run` on the Plugin resource that accepts the arguments `id` (UUID), `function_name` (string of 1 to 255 bytes), and `args` (list of 0 to 64 numbers), and SHALL call `ChimeraRuntime.Runner.Engine.run/4` with `run_mode: :standard` and no other path to Wasmex.
6. THE tool `run_plugin` SHALL read the Plugin fresh by `id`, and SHALL return a map `%{"status" => "success", "output" => list, "wall_time_us" => integer}` only on success. Every failure SHALL be returned as a tool-level error whose message is a category of at most 300 characters: `timeout`, `invalid_input`, `not_active`, `compile_error`, `trap`, or `error` for Engine errors, plus `busy`, `not_found`, and `timeout_too_long_for_mcp` for the guard checks.
7. WHEN the Engine returns `{:error, reason}`, THE tool `run_plugin` SHALL return a tool-level error result whose message names the failure category and omits stack traces and internal module names.
8. IF the Run_Capacity_Guard rejects the call, THEN THE tool `run_plugin` SHALL return the error `busy` without calling the Engine.
9. IF the `timeout_ms` of the Plugin is greater than the configured `mcp_max_timeout_ms` (default 30000), THEN THE tool `run_plugin` SHALL return the error `timeout_too_long_for_mcp` without calling the Engine.
10. THE tool `quarantine_plugin` SHALL expose the Plugin `:quarantine` update action, identified by `id`, with the MCP annotation `destructive_hint: true`.
11. IF the `quarantine_plugin` tool is called on a Plugin in `:quarantined`, THEN THE tool SHALL return the Phase 1 invalid-transition error identifying the current state, and SHALL leave the Plugin unchanged.
12. THE MCP_Server SHALL NOT expose any tool that creates, updates, destroys, compiles, or activates a Plugin, that marks verification used, that runs in the `:verification` Run_Mode, or that reads `wasm_binary` or `source_code`.
13. THE MCP_Server SHALL be mounted with `forward "/mcp", AshAi.Mcp.Router, tools: [:list_plugins, :inspect_execution_metrics, :run_plugin, :quarantine_plugin], otp_app: :chimera_runtime`.
14. WHEN an MCP client calls `tools/list`, THE MCP_Server SHALL return exactly the four MCP_Tools with their input schemas.
15. WHEN any MCP_Tool call changes an Execution or a Plugin, THE change SHALL be published through the events of Requirement 5, so that the Control_Room shows MCP activity.
16. THE `ash_ai` API facts used by this requirement (the `tools` DSL on a domain using the `AshAi` extension, `tool name, resource, action` with `select`, `load`, `get_by`, `identity`, `filterable_fields`, `sortable_fields`, and `annotations`, and `AshAi.Mcp.Router` options `tools` and `otp_app`) SHALL be verified against the source of the pinned version in `deps/ash_ai` before implementation, and IF an option is not confirmed, THEN THE implementation process SHALL stop work that depends on that option and report the gap to the user without altering `mix.exs`.

### Requirement 15: MCP Authentication and Safety

**User Story:** As a security-conscious operator, I want the MCP endpoint unreachable by unauthenticated remote callers, so that agents are the only ones who can run or quarantine plugins, even though the demo dashboard is open.

#### Acceptance Criteria

1. THE router SHALL pipe the `/mcp` scope through a pipeline that runs the MCP_Guard before the MCP_Server.
2. WHERE the environment is `:dev` or `:test`, THE MCP_Guard SHALL admit a Loopback_Request without a token, controlled by `config :chimera_runtime, :mcp, allow_loopback_without_token?: true`.
3. WHERE the environment is `:prod`, THE default of `allow_loopback_without_token?` SHALL be false, so that every request needs a valid token, and THE `config/runtime.exs` SHALL raise at boot IF `CHIMERA_MCP_TOKEN` is missing or shorter than 32 bytes.
4. IF a request is not a Loopback_Request or loopback access is not allowed, THEN THE MCP_Guard SHALL require an `authorization` header of the form `Bearer <token>` and SHALL compare the token with the configured token using `Plug.Crypto.secure_compare/2`.
5. IF the token is missing or does not match, THEN THE MCP_Guard SHALL halt the request with status 401 and a JSON error body, and SHALL NOT call any MCP_Tool.
6. IF no MCP token is configured (possible only in `:dev` and `:test`) and the request is not an admitted Loopback_Request, THEN THE MCP_Guard SHALL halt the request with status 503 and SHALL NOT call any MCP_Tool.
7. THE MCP token SHALL be read at runtime from the environment variable `CHIMERA_MCP_TOKEN` in `config/runtime.exs`, SHALL be required in `:prod`, SHALL NOT appear in source or logs, and SHALL be at least 32 bytes long WHEN configured.
8. IF a request carries an `Origin` header whose value is not in the configured `allowed_origins` list, THEN THE MCP_Guard SHALL halt the request with status 403.
9. THE MCP_Guard SHALL decide Loopback_Request from `conn.remote_ip` only, and SHALL NOT trust `x-forwarded-for` or similar headers.
10. THE MCP_Guard SHALL halt a request with a body larger than 65536 bytes with status 413.
11. THE MCP_Server SHALL validate every tool input against the action's argument types and constraints, and SHALL reject an invalid UUID, an invalid function name, or an invalid argument list with a tool-level error without calling the Engine.
12. THE MCP_Server SHALL introduce no Ash policies and no actor in Phase 2, and the transport layer (MCP_Guard) is the sole authorization boundary.
13. FOR ALL combinations of environment, loopback flag, configured token, supplied token, and Origin header, the MCP_Guard decision function SHALL return exactly one of `:allow`, `{:deny, 401}`, `{:deny, 403}`, `{:deny, 503}`, and SHALL return `:allow` only WHEN the Origin passes and either an admitted Loopback_Request or a matching token applies.

### Requirement 16: Phase 1 Contract Preservation

**User Story:** As a maintainer, I want Phase 1 contracts left intact, so that the Phase 1 test suite and guarantees still hold.

#### Acceptance Criteria

1. THE Phase 2 implementation SHALL leave the source of `lib/chimera_runtime/runner/engine.ex` and `lib/chimera_runtime/runner/worker.ex` unchanged.
2. THE Phase 2 implementation SHALL keep the Engine return contract (`{:ok, list}` or `{:error, reason}`), totality, gate truth table, Execution persistence, and one-shot verification semantics unchanged.
3. THE Phase 2 implementation SHALL keep every Phase 1 Plugin and Execution attribute, action, state transition, aggregate, calculation, and identity unchanged.
4. THE Phase 2 implementation SHALL limit changes to Phase 1 modules to: adding the `Ash.Notifier.PubSub` notifier and its `pub_sub` section to Plugin and Execution, adding the generic action `:run` to Plugin, adding the `AshAi` extension and its `tools` section to the Sandbox_Domain, adding code interfaces to the Sandbox_Domain, and adding the new children in `application.ex`.
5. WHEN `mix ash.codegen --check` runs after the Phase 2 changes, THE command SHALL report no pending migration and no snapshot change.
6. THE Phase 2 implementation SHALL keep Wasmex with WASI disabled as the only WebAssembly runtime, and SHALL execute every Wasm module (including the Chaos_Plugin and Gravedigger runs) only through the Engine.
7. THE Phase 2 implementation SHALL NOT create a `ChimeraRuntime.Audit` domain, and the Version resource SHALL remain in the Sandbox_Domain.
8. THE Phase 2 implementation SHALL use the existing application configuration keys (`fuel_budget`, `:execution_recorder`) without redefining them.
9. THE Phase 2 implementation SHALL record these Phase 1 caveats in the design and respect them in the code: an abandoned timed-out Wasm instance keeps running on a dirty scheduler until its Fuel_Budget is exhausted; `Engine.run/4` is synchronous and holds the caller until the Worker result or Deadline; SQLite allows one writer at a time, so concurrent writes can fail with "database is locked".

### Requirement 17: Test Suite

**User Story:** As a maintainer, I want property-based and example-based tests for the pure logic, the saga, the event contract, the LiveView, and the MCP guard, so that Phase 2 behavior is proven.

#### Acceptance Criteria

1. THE Test_Suite SHALL use ExUnitProperties with StreamData generators for pure logic and SHALL run each property for a minimum of 100 iterations.
2. THE Test_Suite SHALL include a property for the Args_Codec round trip (Requirement 3, criterion 9) and a property that the Args_Codec parse function is total (Requirement 3, criterion 10).
3. THE Test_Suite SHALL include a property for the duration formatter round trip (Requirement 4, criterion 8).
4. THE Test_Suite SHALL include a property for the Event_Payload builders (Requirement 5, criteria 11 and 12).
5. THE Test_Suite SHALL include a property for the Chaos_Gate decision function (Requirement 8, criterion 14).
6. THE Test_Suite SHALL include a property for the MCP_Guard decision function (Requirement 15, criterion 13).
7. THE Test_Suite SHALL include a property for the byte formatter (Requirement 7, criterion 6).
8. THE Test_Suite SHALL include a property over injected Engine verification outcomes asserting the Saga_Result invariants of Requirement 13, criterion 8, using the injectable verification runner.
9. THE Test_Suite SHALL include example-based saga tests using real Wasm fixtures: a successful publish of the `add` fixture ending `:active` with one `:verification` Execution; a publish of the `infinite_loop` fixture ending `:quarantined` with `compensation: :quarantined` and an Execution with status `:timeout`; a trap fixture publish ending `:quarantined`; a publish of a Plugin without `wasm_binary` returning stage `:preflight` with reason `:missing_binary` and state `:draft`; a publish of a Plugin in `:active` returning `{:invalid_state, :active}` with no change; a publish with an already consumed `verification_used` returning the `:preflight` error `:verification_already_used`; and two concurrent publishes of the same Plugin where one returns `:publish_in_progress`.
10. THE Test_Suite SHALL include an example-based test with an injected failing quarantine function asserting `compensation: {:failed, reason}`, `plugin_state: :compiling`, and exactly one error log entry (via `ExUnit.CaptureLog`).
11. THE Test_Suite SHALL include LiveView tests with `Phoenix.LiveViewTest` and `lazy_html` for: mounting `/control-room` (disconnected and connected); the registry table rendering Plugins after `render_async/1` and updating after an Execution is created; a console run showing the output and the Wall_Time; an invalid-JSON submission calling no Engine; a chaos run returning "contained" with the LiveView pid unchanged and the next click rejected by the cooldown; and an Execution_Log entry appearing from a broadcast.
12. THE Test_Suite SHALL run LiveView and Sandbox-backed tests with `async: false` and the shared Ecto SQL sandbox mode, because SQLite has a single writer and Cinder and `start_async` run in processes other than the test process.
13. THE Test_Suite SHALL include an example-based test that an Execution create broadcasts exactly one `"execution_recorded"` event with the key set of Requirement 5, a Plugin transition broadcasts one `"plugin_changed"` event, and a rejected create broadcasts none.
14. THE Test_Suite SHALL include example-based MCP tests that issue JSON-RPC requests to `/mcp` through `Phoenix.ConnTest` for: `tools/list` returning exactly four tools; `list_plugins` returning no `wasm_binary` field; `run_plugin` on the `add` fixture returning the known value; `run_plugin` on a non-active Plugin returning a tool error; `quarantine_plugin` moving an active Plugin to `:quarantined` and failing on a second call; and the MCP_Guard cases of Requirement 15 (missing token, wrong token, bad Origin, loopback allowed, 503 without a configured token).
15. THE Test_Suite SHALL include an example-based test asserting that the checked-in Chaos_Plugin module bytes equal `ChimeraRuntime.WasmFixtures.infinite_loop/0`.
16. THE Test_Suite SHALL include an example-based test asserting that `Engine` and `Worker` source files are unchanged from the Phase 1 content hash recorded in the tests, or equivalently that `mix ash.codegen --check` reports no changes (Requirement 16, criteria 1 and 5).
17. THE Phase 1 Test_Suite SHALL continue to pass unchanged.
18. THE Test_Suite SHALL include an example-based test that `GET /control-room` returns status 200 without any `authorization` header, and that the rendered page contains the "Demo mode: open access" banner (Requirement 1, criteria 10 and 12).

### Requirement 18: Dependency Governance and Quality Gate

**User Story:** As a project owner, I want control over dependency changes and a clean precommit, so that the dependency lock stays intact and the code stays formatted and warning-free.

#### Acceptance Criteria

1. THE Phase 2 implementation SHALL use Wasmex, with WASI disabled, as the only WebAssembly runtime.
2. THE Phase 2 implementation SHALL leave every existing dependency entry in `mix.exs` unchanged, with no entry removed, commented out, or altered in name, version requirement, or options.
3. THE implementation process SHALL treat user approval as granted for adding exactly one dependency, `ash_ai`, to `mix.exs`, and for the six `mix.lock`-only additions `ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case`.
4. WHEN adding `ash_ai` to `mix.exs`, THE implementation process SHALL add it with an exact pinned version requirement (for example `{:ash_ai, "== 1.5.4"}`), SHALL choose the version by verifying on Hex that it is compatible with the locked `ash` 3.37.4, and SHALL leave all other `mix.exs` entries unchanged.
5. WHEN `mix deps.get` resolves `ash_ai`, THE implementation process SHALL list every new package added to `mix.lock` (expected: `ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case`) in its report to the user, and SHALL record the `mix.lock` diff.
6. IF resolving `ash_ai` requires changing the locked version of any existing dependency, requires adding any other `mix.exs` entry, or adds any `mix.lock` package other than the six approved in criterion 3, THEN THE implementation process SHALL stop work that depends on the change, request explicit user approval naming the dependency, and leave `mix.exs` and `mix.lock` unmodified until the user responds.
7. IF the user denies or does not respond to a dependency approval request raised under criterion 6 (a package, version change, or `mix.exs` line outside the approval of criterion 3), THEN THE implementation process SHALL restore `mix.exs` and `mix.lock` to their saved state and report the dependent work (Requirements 14 and 15) as blocked for that reason only, while the Control_Room and the Publish_Saga work SHALL proceed because they need no new dependency.
8. WHEN `ash_ai` has been added to `mix.exs`, THE implementation process SHALL run `mix usage_rules.sync --yes` so that the Ash and Phoenix skills stay up to date.
9. THE implementation process SHALL run `mix precommit` (compile with warnings as errors, `deps.unlock --unused`, format, test) as its final task and SHALL fix every reported failure.
10. WHEN `mix precommit` completes, THE implementation process SHALL confirm with `git diff` that `mix.exs` changed only by the single pinned `ash_ai` line and that `deps.unlock --unused` removed no entry that Phase 1 or Phase 2 uses.
11. IF the new `mix.lock` entries include any package other than the six approved packages `ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case`, THEN THE implementation process SHALL stop, name each additional package to the user, and request explicit approval before keeping the lockfile change.
