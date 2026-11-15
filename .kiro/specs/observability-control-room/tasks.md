# Implementation Plan: Observability Control Room and Agentic Orchestration

## Overview

Implementation proceeds from the dependency preflight, through pure modules and safeguards, the event contract, the Chaos_Plugin, the publish saga, the Control_Room, and the MCP surface, and ends with the quality gate. Language: Elixir. Every task follows the project `AGENTS.md` (Phoenix 1.8 `<Layouts.app>`, `<.input>`, `<.icon>`, Tailwind and DaisyUI, no `@apply`, no inline scripts, `Req` for HTTP) and the workspace dependency lock (Wasmex with WASI disabled, no `mix.exs` change beyond the single pinned `ash_ai` line).

Hard rules for every task:

- Do not edit `lib/chimera_runtime/runner/engine.ex` or `lib/chimera_runtime/runner/worker.ex`.
- Do not change existing `mix.exs` entries. Only task 1.1 touches `mix.exs`.
- Keep the Control_Room open (no authentication) with the Demo_Exposure_Note, and keep `/mcp` guarded.
- Run LiveView and Sandbox-backed tests with `async: false`.

## Tasks

- [ ] 1. Dependency preflight for `ash_ai`
  - [ ] 1.1 Add `ash_ai` with an exact pin and record the lockfile diff
    - Save the current `mix.lock` (for example with `git diff` baseline or a copy outside the repo).
    - Confirm on Hex that the chosen `ash_ai` version is compatible with the locked `ash` 3.37.4 (1.5.4 requires `ash ~> 3.33 and >= 3.33.6`). Add exactly one line to `mix.exs`, for example `{:ash_ai, "== 1.5.4"}`. Do not change any other `mix.exs` line.
    - Run `mix deps.get`. Record the `mix.lock` diff and list every new package.
    - The user APPROVED these six `mix.lock`-only additions: `ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, and `conv_case`. Keep them without asking, and list them in the report.
    - STOP and ask the user before keeping the change if any existing locked version changed, if any `mix.exs` line beyond the single `ash_ai` pin is needed, or if the new lock entries include any package other than those six. Until the user answers, leave the lockfile change unapplied (revert `mix.exs` and `mix.lock` to the saved state) and mark Requirements 14 and 15 work as blocked for that reason only. Tasks outside the MCP group proceed.
    - Run `mix compile` to confirm the project builds with the new dependency.
    - _Requirements: 18.2, 18.3, 18.4, 18.5, 18.6, 18.7, 18.11_

  - [ ] 1.2 Re-verify the `ash_ai` API facts against the pinned source
    - Read `deps/ash_ai` and confirm each fact used by the design: the `tools` section and `tool name, resource, action` form; options `select`, `load`, `get_by`, `identity`, `filterable_fields`, `sortable_fields`, `action_parameters` (and that omitting `:result_type` removes aggregate and count calls), `annotations` (including `destructive_hint`, `read_only_hint`, `open_world_hint`); generic-action tools; union argument types in generated JSON schema; `AshAi.Mcp.Router` options `tools` and `otp_app`; which request field the router reads for tool arguments (`conn.body_params` or `conn.params`); whether `tool_argument_transformer` can be passed through `forward`.
    - Write the confirmed facts and any deviation into the task report. If an option is not confirmed, stop the dependent work and report the gap to the user without altering `mix.exs`.
    - _Requirements: 14.16_

  - [ ] 1.3 Sync usage rules
    - Run `mix usage_rules.sync --yes` so the Ash and Phoenix skills stay current.
    - Confirm `git status` shows no unintended changes outside the usage-rules output.
    - _Requirements: 18.8_

- [ ] 2. Configuration and SQLite safeguards
  - [ ] 2.1 Add configuration keys and the busy timeout
    - In `config/config.exs` add `ChimeraRuntime.RunGuard` (`max_workers: 8`), `:chaos` (`deadline_ms: 250`, `cooldown_ms: 2000`), `:mcp` (`allow_loopback_without_token?: false`, `allowed_origins: []`, `mcp_max_timeout_ms: 30_000`), and `ChimeraRuntime.Orchestration` (`verification_runner`, `quarantine_fun` defaults). Do not redefine `fuel_budget` or `:execution_recorder`.
    - In `config/dev.exs` and `config/test.exs` set `allow_loopback_without_token?: true` for `:mcp`.
    - In `config/dev.exs` add `busy_timeout: 5000` (or higher) to the existing `ChimeraRuntime.Repo` block. In `config/runtime.exs` add `busy_timeout: 5000` (or higher) to the prod `ChimeraRuntime.Repo` block. Verify that the installed `ecto_sqlite3` accepts `:busy_timeout`, and leave the WAL journal mode unchanged.
    - In `config/runtime.exs` read `CHIMERA_MCP_TOKEN`: in `:prod`, raise at boot when it is missing or shorter than 32 bytes; in other environments configure it only when present. Never log the value.
    - _Requirements: 9.1, 9.7, 9.8, 13.9, 14.9, 15.2, 15.3, 15.7, 16.8_

- [ ] 3. Pure helpers: argument codec and formatters
  - [ ] 3.1 Implement `ChimeraRuntimeWeb.ControlRoom.ArgsCodec`
    - `parse/1` checks `byte_size` first (over 4096 returns `{:error, :too_large}` before decoding), treats blank text as `{:ok, []}`, decodes with `Jason.decode/1` without atom keys, and validates shape (array, at most 64 elements, every element a number). Wrap so no input raises.
    - `print/1` encodes a list of finite numbers to JSON array text.
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.10_

  - [ ]* 3.2 Write property test for the ArgsCodec round trip
    - **Property 1: Args_Codec round trip**
    - **Validates: Requirements 3.2, 3.8, 3.9**

  - [ ]* 3.3 Write property test for ArgsCodec totality and classification
    - **Property 2: Args_Codec is total and classifies every input**
    - Include generators for arbitrary binaries, nested JSON, oversized texts, and blank texts.
    - **Validates: Requirements 3.1, 3.3, 3.4, 3.5, 3.6, 3.7, 3.10**

  - [ ] 3.4 Implement `ChimeraRuntimeWeb.ControlRoom.Format`
    - `duration/1` (integer arithmetic: `"412 µs"` below 1000, `"12.345 ms"` otherwise) and `parse_duration/1` as its inverse.
    - `bytes/1` with units B, KiB, MiB, GiB, TiB. `percent/1` (one decimal) and `avg_ms/1` (up to three decimals, or `"n/a"` for nil).
    - _Requirements: 2.4, 2.6, 4.7, 7.3_

  - [ ]* 3.5 Write property test for the duration round trip
    - **Property 3: Duration format round trip**
    - **Validates: Requirements 4.7, 4.8**

  - [ ]* 3.6 Write property test for the byte formatter
    - **Property 6: Byte formatter**
    - **Validates: Requirements 7.6**

- [ ] 4. Run safeguards, coalescing, and vitals
  - [ ] 4.1 Implement `ChimeraRuntime.RunGuard`
    - `decide/2` is pure (`:ok` when `active < max`, else `{:error, :busy}`). `check/0` reads `Supervisor.count_children(ChimeraRuntime.Runner.TaskSupervisor).active` and `max_workers` from config. No lock is held.
    - _Requirements: 9.1, 9.3_

  - [ ]* 4.2 Write property test for the capacity guard
    - **Property 9: Run_Capacity_Guard threshold**
    - **Validates: Requirements 9.1**

  - [ ] 4.3 Implement `ChimeraRuntime.Chaos.Gate` and supervise it
    - Pure `decide(state, event, now)` with state `%{in_flight, last_end}`; GenServer `acquire/1` (monitors the calling process), `release/1`, and release on `:DOWN` so an abnormal exit still frees the slot and starts the cooldown.
    - Read `cooldown_ms` from config. Add the gate as a child in `lib/chimera_runtime/application.ex` after the PubSub child and before the Endpoint.
    - _Requirements: 8.4, 8.5, 8.6, 8.12, 8.14_

  - [ ]* 4.4 Write property test for the Chaos_Gate
    - **Property 8: Chaos_Gate never overlaps and honors the cooldown**
    - **Validates: Requirements 8.5, 8.6, 8.12, 8.14**

  - [ ] 4.5 Implement `ChimeraRuntimeWeb.ControlRoom.Refresh`
    - `on_event(ref, delay_ms)` returns `{:schedule, delay_ms}` for `nil` and `:already_scheduled` otherwise.
    - _Requirements: 6.3, 6.4_

  - [ ]* 4.6 Write property test for refresh coalescing
    - **Property 10: Refresh coalescing**
    - **Validates: Requirements 6.3, 6.4**

  - [ ] 4.7 Implement `ChimeraRuntime.Vitals`
    - `collect/1` reads memory, schedulers, dirty CPU schedulers, run queue, process count, active Workers, and a `:scheduler` sample. Return a fixed-key map and the new sample, or `:error`. Wrap in `try/rescue/catch`. `utilization_percent/1` is pure and clamps to 0.0 to 100.0.
    - _Requirements: 7.2, 7.3, 7.4, 7.5, 7.7_

  - [ ]* 4.8 Write property test for scheduler utilization
    - **Property 7: Scheduler utilization is a bounded percentage**
    - **Validates: Requirements 7.4**

- [ ] 5. Event contract and PubSub notifiers
  - [ ] 5.1 Implement `ChimeraRuntime.Sandbox.EventPayload`
    - `execution/1` and `plugin/1` build the payload maps (truncate `error_reason` to 200 characters; never include `input_json`, `output_json`, `wasm_binary`, or `source_code`). Accept a notification or a bare record. Add `valid_execution?/1` and `valid_plugin?/1`.
    - _Requirements: 5.2, 5.3, 5.5, 5.7_

  - [ ]* 5.2 Write property test for the Execution payload
    - **Property 4: Execution payload contract**
    - **Validates: Requirements 5.2, 5.3, 5.11**

  - [ ]* 5.3 Write property test for the Plugin payload
    - **Property 5: Plugin payload contract**
    - **Validates: Requirements 5.5, 5.12**

  - [ ] 5.4 Add the `Ash.Notifier.PubSub` notifier to Execution and Plugin
    - In `execution.ex` add `notifiers: [Ash.Notifier.PubSub]` and a `pub_sub` section (`module ChimeraRuntimeWeb.Endpoint`, `prefix "sandbox"`, `publish :create, "executions", event: "execution_recorded", transform: &EventPayload.execution/1`).
    - In `plugin.ex` add the notifier and one `publish ... "plugins", event: "plugin_changed"` line each for `:create`, `:update`, `:compile`, `:activate`, `:quarantine`. Do not publish `:mark_verification_used`. Place the `pub_sub` section after `actions` (project formatter order).
    - Change nothing else in these two resources. Confirm `mix ash.codegen --check` reports no change.
    - _Requirements: 5.1, 5.4, 5.6, 5.7, 5.8, 5.10, 16.3, 16.4, 16.5_

  - [ ]* 5.5 Write example tests for the notifier
    - One `"execution_recorded"` per create with the exact key set; one `"plugin_changed"` per transition; none for a rejected create; none for `:mark_verification_used`; the Engine still returns its result when the broadcast fails.
    - _Requirements: 5.1, 5.4, 5.6, 5.9, 5.10, 17.13_

- [ ] 6. Chaos_Plugin
  - [ ] 6.1 Implement `ChimeraRuntime.Chaos.Plugin`
    - `wasm/0` holds the infinite-loop byte literal in `lib/`. `ensure_active/0` returns the existing Plugin, or creates, compiles, and activates `chaos-chamber` through the Sandbox_Domain without the Gravedigger. Treat a unique-name error as "read the existing Plugin". `timeout_ms` comes from `:chaos` `deadline_ms`, validated to 10 to 1000. Report the state when the Plugin is not `:active`.
    - _Requirements: 8.2, 8.3, 8.8_

  - [ ]* 6.2 Write tests for the Chaos_Plugin
    - Assert `Chaos.Plugin.wasm/0` equals `ChimeraRuntime.WasmFixtures.infinite_loop/0`; creation and activation on first call; a non-active existing Plugin is reported and not modified.
    - _Requirements: 8.2, 8.3, 8.8, 17.15_

- [ ] 7. Publish saga
  - [ ] 7.1 Implement `StageError` and `Result`
    - `StageError` struct (`stage`, `reason`). `Result` shapes saga results: unwrap `Reactor.Error.*` wrappers to the first `StageError`, derive `compensation` (`:not_needed` for `:lock`, `:preflight`, `:compile`; `{:failed, reason}` when `UndoStepError` or `UndoRetriesExceededError` is present; otherwise `:quarantined`), and build the error map.
    - _Requirements: 13.2, 13.3, 13.7_

  - [ ] 7.2 Implement the four `Reactor.Step` modules
    - `LoadPlugin` (preflight with `Engine.validate_input/4`, `:not_found`, `{:invalid_state, state}`, `:missing_binary`, `:verification_already_used`), `BeginCompile` (compile; `undo/4` re-reads and quarantines, treating `:quarantined` as success, returning `:retry` on SQLite busy or locked errors, logging once on permanent failure), `Verify` (configured runner, `run_mode: :verification`, raise/exit/throw converted to `StageError`), `Promote` (fresh read, `activate_plugin`).
    - Read `verification_runner` and `quarantine_fun` from application config at run time.
    - _Requirements: 10.5, 10.6, 10.7, 10.8, 10.9, 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 11.10, 12.1, 12.2, 12.3, 12.5, 12.6, 12.8, 12.9, 12.10, 12.11, 13.9_

  - [ ] 7.3 Implement `PublishPluginReactor` and `publish/3`
    - `use Ash.Reactor` with `default_domain ChimeraRuntime.Sandbox`; inputs `plugin_id`, `function_name`, `args` (default `[]`); four steps in order with `async? false` and `max_retries 0`. Check the Reactor DSL against `deps/reactor` while writing it.
    - `publish/3`: validate input shapes; take the lock with `:global.trans/4` (retries 0); run `Reactor.run/4` with `async?: false` and `timeout: :infinity`; read the Plugin state after the run (`:unknown` on a failed read); return exactly one tuple and never raise, exit, or throw. Add no MCP tool and no Control_Room button for the saga.
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.10, 10.11, 10.12, 10.13, 11.11, 12.4, 12.7, 13.1, 13.2, 13.4, 13.5, 13.6_

  - [ ]* 7.4 Write property test for saga outcome invariants
    - **Property 13: Saga outcome invariants**
    - Inject outcomes through `verification_runner` against a `:draft` Plugin with a binary, in an `async: false` module.
    - **Validates: Requirements 10.8, 10.10, 11.7, 12.2, 12.4, 13.1, 13.2, 13.7, 13.8**

  - [ ]* 7.5 Write property test for `publish/3` totality
    - **Property 14: publish/3 is total**
    - **Validates: Requirements 13.2, 13.4**

  - [ ]* 7.6 Write example saga tests with real Wasm fixtures
    - `add` ends `:active` with one `:verification` Execution; `infinite_loop` ends `:quarantined` with `compensation: :quarantined` and a `:timeout` Execution; `trap_unreachable` ends `:quarantined`; no binary returns `:preflight` / `:missing_binary` with state `:draft`; an `:active` Plugin returns `{:invalid_state, :active}` unchanged; a consumed one-shot returns `:verification_already_used`; two concurrent publishes return one `:publish_in_progress`.
    - _Requirements: 10.10, 11.2, 11.3, 11.4, 11.5, 12.4, 12.10, 12.11, 13.5, 17.9_

  - [ ]* 7.7 Write the failing-compensation test
    - Inject a failing `quarantine_fun`; assert `compensation: {:failed, reason}`, `plugin_state: :compiling`, and exactly one error log entry with `ExUnit.CaptureLog`.
    - _Requirements: 12.6, 12.7, 17.10_

- [ ] 8. Control_Room LiveView
  - [ ] 8.1 Add the route and the `:control_room_access` pipeline
    - In `router.ex` add `pipeline :control_room_access` with no authentication plug and a comment recording the Demo_Exposure_Note and how to add auth later. Add `scope "/", ChimeraRuntimeWeb do pipe_through [:browser, :control_room_access]; live "/control-room", DashboardLive end`. Keep it outside `/dev/dashboard`.
    - _Requirements: 1.1, 1.9, 1.10, 1.11, 1.13_

  - [ ] 8.2 Implement `ChimeraRuntimeWeb.ControlRoomComponents`
    - Function components: demo banner ("Demo mode: open access"), `registry_panel` (`Cinder.collection id="plugin-registry"` over a `query` with `select`, slots `:empty` "No plugins yet" and `:error`, "system" badge for `chaos-chamber`), `console_panel` (selector, function name, args textarea through `<.input>`, "Run" button disabled while running, result block, Wall_Time note), `vitals_panel` (telemetry cards, "stale" marker), `chaos_chamber` (button, help text on abandoned Workers, result), and the execution log entry. Use `<.icon>`, Tailwind and DaisyUI classes, plain CSS in `assets/css/app.css` if needed (no `@apply`, no inline script, no external assets).
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 1.12, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 4.1, 4.4, 4.9, 7.3, 7.4, 7.7, 8.1, 8.13_

  - [ ] 8.3 Implement `ChimeraRuntimeWeb.DashboardLive`
    - `@moduledoc` carries the Demo_Exposure_Note. Mount subscribes to `sandbox:executions` and `sandbox:plugins`, starts the 1000 ms vitals timer and the 30 s fallback timer only when connected, and builds the registry query with `Ash.Query.select(Plugin, [:id, :name, :state, :timeout_ms])`. Selector options load with `assign_async`.
    - Console: parse with `ArgsCodec`, then `start_async(:console_run, ...)` running `RunGuard.check/0` and `Engine.run/4` with `run_mode: :standard` in the task. Chaos: `start_async(:chaos_run, ...)` running the fuel check, `Gate.acquire`, `Chaos.Plugin.ensure_active/0`, `RunGuard.check/0`, `Engine.run/4`, and `Gate.release` in `after`. Compare the LiveView pid before and after for "LiveView process unchanged". Handle `{:exit, reason}` for both.
    - Broadcast handling: validate payloads with `EventPayload.valid_*?`, insert log entries into a stream (`at: 0`, `limit: 50`), coalesce refreshes (250 ms) with `Refresh.on_event/2`, refresh the selector on Plugin events, ignore malformed messages.
    - _Requirements: 1.7, 1.8, 4.2, 4.3, 4.5, 4.6, 4.10, 4.11, 4.12, 4.13, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 7.1, 7.8, 8.4, 8.5, 8.6, 8.7, 8.9, 8.10, 8.11, 9.2, 9.4, 9.5, 9.6_

  - [ ]* 8.4 Write LiveView tests
    - Disconnected and connected mount; `GET /control-room` returns 200 without an `authorization` header and shows "Demo mode: open access"; registry renders after `render_async/1` and updates after an Execution create; the registry query excludes `wasm_binary` and `source_code`; console run shows output and Wall_Time; invalid JSON calls no Engine; busy rejection; chaos shows "contained" with the pid unchanged and the next click is rejected by the cooldown; a broadcast inserts a log entry; a malformed broadcast is ignored. Use `async: false`.
    - _Requirements: 1.1, 1.8, 1.10, 1.12, 2.1, 2.5, 4.2, 4.5, 4.10, 6.1, 6.7, 8.9, 8.11, 17.11, 17.12, 17.18_

- [ ] 9. MCP server
  - [ ] 9.1 Implement the `WasmNumber` Ash type and spike the schema
    - `ChimeraRuntime.Sandbox.Types.WasmNumber` as a union of `integer` and `float`. Write a spike test that casts `5` (stays integer) and `5.5` (stays float), and that the ash_ai tool JSON schema for an array of this type is valid. If the type or schema fails, stop and report; the fallback (a JSON-text `args` argument parsed by `ArgsCodec`) changes Requirement 14, criterion 5 and needs user sign-off.
    - _Requirements: 14.5, 14.16, 15.11_

  - [ ] 9.2 Add the generic action `:run` to Plugin with `Plugin.Run`
    - Add `action :run, :map` to `plugin.ex` with arguments `id`, `function_name` (1 to 255), `args` (0 to 64 `WasmNumber`) and `run ChimeraRuntime.Sandbox.Plugin.Run`. The implementation reads the Plugin fresh, checks `timeout_ms` against `mcp_max_timeout_ms` (`timeout_too_long_for_mcp`), calls `RunGuard.check/0` (`busy`), unwraps union values, calls `Engine.run/4` with `run_mode: :standard`, and returns `%{"status", "output" | "reason", "wall_time_us"}`. Engine errors return tool-level error messages (category only, at most 300 characters, no module names or stack traces).
    - _Requirements: 9.2, 14.5, 14.6, 14.7, 14.8, 14.9, 14.11, 15.11, 16.4_

  - [ ] 9.3 Add the `AshAi` extension and `tools` section to the Sandbox_Domain
    - In `sandbox.ex` add `extensions: [AshAi]` and the four tools exactly as in the design (`list_plugins`, `inspect_execution_metrics`, `run_plugin`, `quarantine_plugin`), using the options confirmed in task 1.2. Add only code interfaces that the tests need. Keep every existing interface.
    - Confirm with the real tool JSON that `wasm_binary` and `source_code` never appear in tool output.
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.10, 14.12, 14.15, 15.12, 16.4_

  - [ ] 9.4 Implement `McpGuard` and `McpLimits`
    - `McpGuard.decide/1` (pure; Origin 403, loopback allow, no token 503, bad token 401, else allow, using `Plug.Crypto.secure_compare/2`, `conn.remote_ip` only) and `body_size_decision/1` (413 above 65536 or missing length on a request with a body). The plug halts with a JSON error body.
    - `McpLimits.clamp_limit/1` caps the `list_plugins` `limit` at 100, applied to the field confirmed in task 1.2.
    - _Requirements: 14.3, 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.8, 15.9, 15.10_

  - [ ]* 9.5 Write property test for the MCP_Guard decision
    - **Property 11: MCP_Guard decision**
    - **Validates: Requirements 15.2, 15.3, 15.4, 15.5, 15.6, 15.8, 15.9, 15.13**

  - [ ]* 9.6 Write property test for the body size decision
    - **Property 12: Body size decision**
    - **Validates: Requirements 15.10**

  - [ ] 9.7 Mount the MCP server in the router
    - In `router.ex` add `pipeline :mcp` (`McpGuard`, `McpLimits`) and `forward "/mcp", AshAi.Mcp.Router, tools: [:list_plugins, :inspect_execution_metrics, :run_plugin, :quarantine_plugin], otp_app: :chimera_runtime` inside a scope that pipes through `:mcp`.
    - _Requirements: 14.13, 14.14, 15.1_

  - [ ]* 9.8 Write MCP request tests
    - Via `Phoenix.ConnTest` JSON-RPC: `tools/list` returns exactly four tools; `list_plugins` has no `wasm_binary` or `source_code` and respects the 100 limit cap; `run_plugin` on `add` returns the known value; `run_plugin` on a non-active Plugin returns a tool error; `run_plugin` returns `busy` and `timeout_too_long_for_mcp` without calling the Engine; `quarantine_plugin` quarantines then fails on the second call; guard cases (missing token, wrong token, bad Origin, loopback allowed, 503 without a configured token, 413 for a large body); a tool call changes state and the Control_Room receives the event.
    - _Requirements: 14.2, 14.3, 14.6, 14.7, 14.8, 14.9, 14.11, 14.14, 14.15, 15.4, 15.5, 15.6, 15.8, 15.10, 17.14_

- [ ] 10. Phase 1 contract preservation
  - [ ] 10.1 Verify Phase 1 contracts are intact
    - Run `git diff --stat -- lib/chimera_runtime/runner/engine.ex lib/chimera_runtime/runner/worker.ex` and confirm no change. Run `mix ash.codegen --check` and confirm no pending migration or snapshot change. Run the Phase 1 tests (`mix test test/chimera_runtime`) and confirm they pass unchanged. Confirm no `ChimeraRuntime.Audit` domain exists.
    - _Requirements: 16.1, 16.2, 16.3, 16.5, 16.6, 16.7, 17.16, 17.17_

- [ ] 11. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 12. Final quality gate
  - [ ] 12.1 Run `mix precommit`
    - Run `mix precommit` (compile with warnings as errors, `deps.unlock --unused`, format, test). Fix every reported failure and re-run until it passes.
    - _Requirements: 18.9_

  - [ ] 12.2 Confirm the dependency diff
    - Run `git diff -- mix.exs mix.lock`. Confirm `mix.exs` changed only by the single pinned `ash_ai` line, that `deps.unlock --unused` removed no entry used by Phase 1 or Phase 2, and list the new `mix.lock` packages in the report.
    - _Requirements: 18.2, 18.5, 18.10_

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP.
- Each task references specific requirements for traceability.
- The Control_Room is deliberately open for the demo (Demo_Exposure_Note). The Run_Capacity_Guard and the Chaos_Gate are its only safeguards. `/mcp` is guarded.
- Task 1.1 is a gate only for surprises. The user approved the six expected `mix.lock` additions (`ash_ai`, `ash_json_api`, `open_api_spex`, `json_xema`, `xema`, `conv_case`), so the task asks only for any other new package, any change to an existing locked version, or any additional `mix.exs` line.
- Task 1.2 must re-verify the hexdocs-based `ash_ai` facts against the pinned source before tasks 9.1 to 9.7 start.
- Property tests validate universal correctness properties. Unit and example tests validate specific scenarios.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "1.3", "2.1", "3.1", "3.4", "4.5", "5.1"] },
    { "id": 2, "tasks": ["3.2", "3.3", "3.5", "3.6", "4.1", "4.3", "4.6", "4.7", "5.2", "5.3"] },
    { "id": 3, "tasks": ["4.2", "4.4", "4.8", "5.4", "6.1", "7.1"] },
    { "id": 4, "tasks": ["5.5", "6.2", "7.2", "8.2", "9.1", "9.4"] },
    { "id": 5, "tasks": ["7.3", "8.3", "9.2", "9.5", "9.6"] },
    { "id": 6, "tasks": ["7.4", "7.5", "7.6", "7.7", "8.1", "9.3"] },
    { "id": 7, "tasks": ["8.4", "9.7"] },
    { "id": 8, "tasks": ["9.8", "10.1"] },
    { "id": 9, "tasks": ["12.1"] },
    { "id": 10, "tasks": ["12.2"] }
  ]
}
```
