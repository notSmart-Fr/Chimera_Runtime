# Implementation Plan: Poltergeist Sandbox

## Overview

Implementation language is Elixir (the design uses concrete Elixir code). The plan first verifies the Wasmex 0.16.0 API from source and adds the two pre-approved dependencies, then wires the foundation (Repo, config, Task.Supervisor), builds the Ash resources and the Sandbox domain, then the Runner Engine (fuel metering, deadline backstop, Gravedigger verification mode), and finally the tests and `mix precommit`.

Workspace rules apply throughout: Wasmex with `wasi: false` is the only runtime. Only `ash_sqlite` and `ash_paper_trail` may be added to `mix.exs`, each with an exact `"== x.y.z"` pin. No other `mix.exs` entry is removed, commented out, or altered. The project root for all `mix` commands and relative paths is `d:\Chimera_Runtime`.

## Tasks

- [x] 1. Preflight: verify Wasmex API and add approved dependencies
  - [x] 1.1 Inspect installed Wasmex 0.16.0 source before any Engine work
    - Read `deps/wasmex/lib/wasmex.ex` and confirm the `Wasmex.start_link/1` option shapes (`:bytes`, `:imports`, `:links`, `:wasi`, `:name`, `:store`, `:module`)
    - Read `deps/wasmex/lib/wasmex/pipe.ex` and `deps/wasmex/lib/wasmex/wasi/` and confirm WASI is disabled by `wasi: false` and that `Wasmex.Pipe` and `WasiOptions` will not be used
    - Read `engine.ex`, `engine_config.ex`, `store.ex`, `store_or_caller.ex`, `module.ex` under `deps/wasmex/lib/wasmex/` and confirm `Engine.new/1` with `consume_fuel: true`, `Store.new/2`, `StoreOrCaller.set_fuel/2`, `get_fuel/1`, `Module.compile/2`
    - Confirm epoch interruption has no Elixir option (`native/wasmex/src/engine.rs`)
    - Confirm the real out-of-fuel trap message text by running a throwaway script or `mix run -e` that builds a fuel-enabled store with a tiny budget, runs a hand-assembled infinite-loop module, and prints the returned `{:error, msg}`; record the message in a code comment for Worker task 5.1 and the fuel example test
    - If any required option does not exist, stop dependent work, report the gap to the user, and do not touch `mix.exs`
    - Delete any throwaway script afterward
    - _Requirements: 6.10, 6.11, 6.12, 7.8, 7.9, 7.10_

  - [x] 1.2 Add `ash_sqlite` and `ash_paper_trail` to `mix.exs` and sync usage rules
    - Look up the current stable versions of both packages and add each to `deps` with an exact pin, for example `{:ash_sqlite, "== x.y.z"}`
    - Add nothing else and leave every existing entry unchanged
    - Run `mix deps.get`, then `mix usage_rules.sync --yes`
    - Read the pinned `deps/ash_paper_trail` source and check for an option that routes the Version_Resource into another domain (design decision D4). Finding: ash_paper_trail 0.8.1 has no such option, so the Version_Resource stays in the Sandbox domain and no Audit domain is created
    - If any other dependency turns out to be required, stop and ask the user for explicit approval
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7_

- [x] 2. Foundation wiring
  - [x] 2.1 Convert the Repo and add configuration
    - Change `lib/chimera_runtime/repo.ex` to `use AshSqlite.Repo, otp_app: :chimera_runtime` (add any callbacks the generator requires)
    - In `config/config.exs` add `ash_domains: [ChimeraRuntime.Sandbox]` under `config :chimera_runtime`
    - Add `config :chimera_runtime, ChimeraRuntime.Runner.Engine, fuel_budget: 10_000_000`, with a smaller override available in `config/test.exs`
    - Keep `default_actions_require_atomic?` and sandbox settings as they are
    - _Requirements: 1.3, 1.4, 7.8, 12.2_

  - [x] 2.2 Add the Task.Supervisor to the supervision tree
    - In `lib/chimera_runtime/application.ex` add `{Task.Supervisor, name: ChimeraRuntime.Runner.TaskSupervisor}` after `ChimeraRuntime.Repo` and before `ChimeraRuntimeWeb.Endpoint`
    - Keep the `:one_for_one` strategy
    - _Requirements: 6.1, 6.3_

  - [x] 2.3 Create Wasm test fixtures
    - Create `test/support/wasm_fixtures.ex` with checked-in hand-assembled byte literals (no WAT compiler, no new dependency)
    - Fixtures: `add` (i32,i32 to i32), `infinite_loop`, `trap_unreachable`, `divide_by_zero`, `module_with_import`, `no_results`
    - Confirm `test/support` is in `elixirc_paths` for the test environment
    - _Requirements: 6.8, 6.9, 8.4, 10.2, 11.11_

- [x] 3. Sandbox Ash resources
  - [x] 3.1 Implement the Plugin resource
    - Create `lib/chimera_runtime/sandbox/plugin.ex` with `AshSqlite.DataLayer` (table `plugins`) and `AshStateMachine` (`:draft` to `:compiling` to `:active`, quarantine from the three live states)
    - Attributes: `name` (1..255), `source_code` (max 1 MiB), `wasm_binary` (max 10 MiB), `timeout_ms` (default 500, 1..600_000), `verification_used` (default false, not publicly writable), `state`
    - Actions: `:create`, `:update`, `:compile`, `:activate` (validation that `wasm_binary` is non-empty, `require_atomic? false`), `:quarantine`, `:mark_verification_used` (internal, atomic with `filter expr(verification_used == false)`, leaves state untouched)
    - Identity `:unique_name` on `name` with message "has already been taken"
    - Aggregates `total_runs`, `avg_duration_ms`, internal `failed_runs`, and calculation `failure_rate` (float division, 0.0 when no runs); no `run_mode` filter
    - `has_many :executions`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 8.11_

  - [x] 3.2 Implement the Execution resource and its validation
    - Create `lib/chimera_runtime/sandbox/validations/error_reason_matches_status.ex` (success requires nil `error_reason`; timeout or error requires a non-blank one)
    - Create `lib/chimera_runtime/sandbox/execution.ex` with `AshSqlite.DataLayer` (table `executions`) and `AshPaperTrail.Resource` (`changes_only`, store action name); the generated `ChimeraRuntime.Sandbox.Execution.Version` stays in the Sandbox domain (no domain-routing option exists in ash_paper_trail 0.8.1)
    - Attributes: `input_json`, `output_json` (nullable), `duration_ms` (0..2_147_483_647), `status` (`:success | :timeout | :error`), `error_reason` (max 2000), `run_mode` (`:standard | :verification`, default `:standard`), `belongs_to :plugin` (`allow_nil? false`, `on_delete: :restrict`)
    - `:create` and `:update` actions with explicit `accept` lists and the validation on both
    - _Requirements: 1.8, 1.9, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 4.11, 4.12, 4.13, 4.14, 4.15_

  - [x] 3.3 Implement the Sandbox domain and generate migrations
    - Create `lib/chimera_runtime/sandbox.ex` registering Plugin, Execution and the generated Execution.Version, with the code interfaces from the design (`create_plugin`, `get_plugin`, `compile_plugin`, `activate_plugin`, `quarantine_plugin`, `mark_verification_used`, `create_execution`, `list_executions`)
    - Add a code interface (`list_execution_versions`) for reading Execution versions on the Sandbox domain
    - Run `mix ash.codegen` and review the generated migrations and `priv/resource_snapshots`; confirm tables `plugins`, `executions`, `executions_versions`
    - Run `mix ash.migrate` (or the project's migrate alias) against dev and test databases
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 1.6, 1.7_

  - [x] 3.4 Write Plugin state machine example tests
    - Create `test/chimera_runtime/sandbox/plugin_test.exs`
    - Cover every valid transition, at least one test per invalid transition with state unchanged, activation with nil or empty binary, defaults, name uniqueness, size limits, and `activate` regardless of `verification_used`
    - _Requirements: 2.2, 2.3, 2.6, 2.9, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.9, 11.12_

  - [x] 3.5 Write property test for invalid transitions
    - Create `test/chimera_runtime/sandbox/plugin_transitions_property_test.exs`
    - **Property 11: Invalid transitions are rejected and leave the Plugin unchanged**
    - **Validates: Requirements 3.6, 3.7, 3.8**

  - [x] 3.6 Write property test for Plugin field validation
    - Create `test/chimera_runtime/sandbox/plugin_validation_property_test.exs`
    - **Property 12: Plugin field validation**
    - **Validates: Requirements 2.1, 2.4, 2.5, 2.7, 2.8**

  - [x] 3.7 Write property test for Execution error_reason and status
    - Create `test/chimera_runtime/sandbox/execution_validation_property_test.exs`
    - **Property 8: Execution error_reason agrees with status**
    - **Validates: Requirements 4.11, 4.12, 4.13**

  - [x] 3.8 Write property test for Execution duration range
    - Create `test/chimera_runtime/sandbox/execution_duration_property_test.exs`
    - **Property 13: Execution duration range**
    - **Validates: Requirements 4.5, 4.6**

  - [x] 3.9 Write Execution example tests
    - Create `test/chimera_runtime/sandbox/execution_test.exs`
    - Assert the Version_Resource is in `Ash.Domain.Info.resources(ChimeraRuntime.Sandbox)` alongside Plugin and Execution, `ChimeraRuntime.Audit` is not defined, and one Execution create produces exactly one version row
    - Cover nil `output_json`, missing or nonexistent plugin reference, invalid `status` and `run_mode`, and no version row on rejected changes
    - _Requirements: 1.2, 1.8, 1.9, 4.2, 4.4, 4.8, 4.10, 4.13, 4.15, 11.19_

  - [x] 3.10 Write property test for failure_rate
    - Create `test/chimera_runtime/sandbox/plugin_aggregates_property_test.exs` (`max_runs: 100`, sequences of 0..50 Executions)
    - **Property 9: failure_rate is bounded and exact**
    - **Validates: Requirements 5.1, 5.3, 5.4, 5.7, 5.8, 11.10**

  - [x] 3.11 Write property test for avg_duration_ms
    - Create `test/chimera_runtime/sandbox/plugin_avg_duration_property_test.exs`
    - **Property 10: Average duration is the mean of non-nil durations**
    - **Validates: Requirements 5.2, 5.5**

- [x] 4. Checkpoint - Resources and migrations
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Runner Engine
  - [x] 5.1 Implement the Worker
    - Create `lib/chimera_runtime/runner/worker.ex` with `invoke/3` and a public `build_store/0` test seam
    - Set `Process.flag(:trap_exit, true)` on the Worker only
    - Build `Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})`, `Wasmex.Store.new(nil, engine)` (no WASI), `StoreOrCaller.set_fuel(store, fuel_budget)` before any call, `Wasmex.Module.compile/2`, then `Wasmex.start_link(%{store: store, module: module, imports: %{}})`. Always compile with `Module.compile/2` first: `start_link` with `:bytes` pattern-matches `{:ok, module}` and raises `MatchError` on invalid bytes
    - Map failures: `{:compile_error, msg}`, `{:instantiation_error, msg}`, `{:unsatisfied_import, msg}`, `{:missing_export, name}`, `{:fuel_exhausted, msg}` (matched first, by substring `"all fuel consumed by WebAssembly"` as confirmed in task 1.1; never match the full string, Wasmex misspells "excecution"), `{:trap, msg}`, `{:call_error, msg}`
    - Stop the Wasmex GenServer in an `after` block
    - _Requirements: 6.7, 6.8, 6.9, 7.8, 7.10, 7.12, 8.2, 8.3, 8.4_

  - [x] 5.2 Implement the Engine validation, gate, and run flow
    - Create `lib/chimera_runtime/runner/engine.ex` with `run/4` (total), `validate_input/4`, `validate_timeout/1`, and public `@doc false` pure `gate/1` implementing the truth table (state before binary, `:verification_already_used` before `:missing_binary`)
    - Start the Worker with `Task.Supervisor.async_nolink/2` on `ChimeraRuntime.Runner.TaskSupervisor`; wait with `Task.yield/2`; on deadline use `Task.shutdown(task, :brutal_kill)` and honor `{:ok, result}` returned from shutdown
    - Measure `duration_ms` with `System.monotonic_time(:millisecond)` and clamp to 2_147_483_647
    - Map outcomes per the design table (fuel exhaustion to `:timeout`, crash to `{:worker_exit, reason}`)
    - Wrap Caller-side code in `try/rescue/catch` returning `{:error, {:runtime_failure, detail}}`
    - _Requirements: 6.1, 6.2, 6.4, 6.5, 6.6, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.13, 8.1, 8.5, 8.6, 8.7, 8.8, 8.9, 8.10, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6_

  - [x] 5.3 Add Execution persistence and Gravedigger one-shot consumption to the Engine
    - Add `consume_verification/2` that calls the atomic `mark_verification_used` from the Caller immediately before starting the Worker; a filter miss returns `{:error, :verification_already_used}`, a persistence failure returns `{:error, :verification_marker_failed}`
    - Add `record_execution/…` in the Caller: build `input_json`, `output_json`, `format_reason/1` (non-empty, at most 1,000 characters, deadline and fuel reasons), `run_mode`, and `plugin_id`
    - Inject the persist function through `Application.get_env(:chimera_runtime, :execution_recorder)`, defaulting to `Sandbox.create_execution/1`
    - On persistence failure call `Logger.error` exactly once, do not retry, and return the original result
    - Create no Execution when the run fails before a Worker started
    - _Requirements: 8.11, 8.12, 8.13, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10_

- [x] 6. Engine tests
  - [x] 6.1 Write property test for invalid Wasm bytes
    - Create `test/chimera_runtime/runner/engine_invalid_bytes_property_test.exs` with three generators: arbitrary bytes 0..4096, `\0asm` prefix plus 0..4096 random bytes, and non-magic first four bytes (including inputs shorter than 4 bytes); `max_runs: 100`
    - **Property 1: Invalid Wasm bytes are rejected without harm**
    - **Validates: Requirements 11.2, 11.3, 11.4, 8.2, 10.3**

  - [x] 6.2 Write property test for failure containment
    - Create `test/chimera_runtime/runner/engine_containment_property_test.exs` (`max_runs: 100`)
    - Assert Caller alive, no `:DOWN`, `:EXIT`, or task-reply messages in the mailbox, and `Task.Supervisor.children/1` empty within 100 ms
    - **Property 2: Failures are contained and leave no residue**
    - **Validates: Requirements 6.2, 6.4, 6.5, 6.6, 8.1, 8.5, 11.6, 11.7**

  - [x] 6.3 Write property test for infinite-loop deadline
    - Create `test/chimera_runtime/runner/engine_deadline_property_test.exs` with `timeout_ms` in 10..500 and `max_runs: 20`
    - Assert `{:error, :timeout}` within `timeout_ms + 100` ms and a follow-up valid run returning `{:ok, output}` within 500 ms
    - **Property 3: Infinite loops hit the deadline and leave no spinning instance**
    - **Validates: Requirements 7.1, 7.3, 7.4, 7.5, 7.12, 7.13, 11.5, 11.16**

  - [x] 6.4 Write property test for Execution counts
    - Create `test/chimera_runtime/runner/engine_recording_property_test.exs` (`max_runs: 100`)
    - **Property 4: Executions are recorded exactly when a Worker started**
    - **Validates: Requirements 9.1, 9.8, 11.8, 11.9**

  - [x] 6.5 Write property test for Execution well-formedness
    - Create `test/chimera_runtime/runner/engine_execution_shape_property_test.exs` (`max_runs: 100`)
    - **Property 5: Recorded Executions are well-formed**
    - **Validates: Requirements 9.1, 9.2, 9.3, 9.7, 9.9, 9.10**

  - [x] 6.6 Write property test for Engine totality
    - Create `test/chimera_runtime/runner/engine_totality_property_test.exs` using `StreamData.term()` for all four arguments (`max_runs: 100`)
    - **Property 6: Engine is total**
    - **Validates: Requirements 10.1, 10.3, 10.4, 10.5, 10.6, 7.2**

  - [x] 6.7 Write property test for the gate truth table
    - Create `test/chimera_runtime/runner/engine_gate_property_test.exs` testing `Engine.gate/1` as a pure function plus one integration check that errors start no Worker and leave the Plugin unchanged (`max_runs: 100`)
    - **Property 7: Gate decision matches the truth table**
    - **Validates: Requirements 8.6, 8.7, 8.8, 8.9, 8.10**

  - [x] 6.8 Write property test for one-shot verification
    - Create `test/chimera_runtime/runner/engine_verification_property_test.exs` covering success, trap, timeout, and import-failure outcomes (`max_runs: 100`, shrinking limited)
    - **Property 14: Verification is one-shot and non-state-changing**
    - **Validates: Requirements 8.11, 8.13, 3.10, 8.10**

  - [x] 6.9 Write Engine example tests
    - Create `test/chimera_runtime/runner/engine_test.exs`
    - Valid `add` module returns the known value; missing export, trap, and unsatisfied import examples; fuel exhaustion with a small budget returns `{:error, {:fuel_exhausted, _}}` and records one `:timeout` Execution; `Worker.build_store/0` yields a finite fuel at most the configured budget; shutdown-race branch returning `{:ok, result}`; persistence failure via `:execution_recorder` logs once (`ExUnit.CaptureLog`) and returns the result unchanged
    - Verification flows: first run succeeds and records one `:verification` Execution, second returns `:verification_already_used` with no Execution, `:standard` on `:compiling` returns `:plugin_not_active`, `:verification` on `:draft`, `:active`, `:quarantined` returns `:plugin_not_active`, and `activate` still succeeds afterward
    - Smoke checks: `ChimeraRuntime.Runner.TaskSupervisor` is registered, both domains are in `:ash_domains`, tables exist
    - _Requirements: 1.3, 1.5, 6.3, 6.9, 7.7, 7.10, 7.11, 8.3, 8.4, 8.10, 8.11, 9.6, 9.10, 11.11, 11.14, 11.15, 11.17, 11.18_

- [x] 7. Checkpoint - Engine complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Final verification
  - [x] 8.1 Run `mix precommit`
    - Run `mix precommit` from `d:\Chimera_Runtime` (compile with warnings as errors, format, test) and fix any failures
    - Confirm via `git diff` that `mix.exs` changed only by the two pinned additions
    - _Requirements: 12.2, 12.3, 12.6_

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- Property tests use StreamData (already in `mix.exs`): at least 100 iterations, and 20 for the infinite-loop property
- Each property test lives in its own file so tasks can run in parallel without file conflicts
- Task 1.1 findings: the out-of-fuel trap message is `{:error, "Error during function excecution (wasm trap: all fuel consumed by WebAssembly): ..."}`; the Worker matches on the substring. Epoch interruption is hard-coded in Wasmex with no Elixir option, so the deadline backstop is `Task.shutdown(:brutal_kill)`. `mix.exs` declares wasmex `~> 0.9` and `mix.lock` pins 0.16.0; leave `mix.exs` unchanged

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["2.1", "2.2", "2.3"] },
    { "id": 3, "tasks": ["3.1", "3.2", "5.1"] },
    { "id": 4, "tasks": ["3.3", "5.2"] },
    { "id": 5, "tasks": ["3.4", "3.5", "3.6", "3.7", "3.8", "3.9", "3.10", "3.11", "5.3"] },
    { "id": 6, "tasks": ["6.1", "6.2", "6.3", "6.4", "6.5", "6.6", "6.7", "6.8", "6.9"] },
    { "id": 7, "tasks": ["8.1"] }
  ]
}
```
