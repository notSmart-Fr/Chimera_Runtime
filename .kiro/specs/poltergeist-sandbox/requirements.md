# Requirements Document

## Introduction

Phase 1 of ChimeraRuntime, "The Poltergeist Sandbox", is an agentic sandbox execution harness. It stores WebAssembly plugins as Ash resources in SQLite, executes each plugin inside an isolated and deadline-bound BEAM worker using Wasmex with WASI disabled, records every execution with an audit history, and proves through property-based tests that rogue modules cannot crash or hang the caller.

The feature has three parts:

1. The `ChimeraRuntime.Sandbox` Ash domain with `Plugin` and `Execution` resources.
2. The `ChimeraRuntime.Runner.Engine` isolation engine.
3. A StreamData property-based test suite for the engine.

### Dependency Status (requires user approval)

Current `mix.exs` was inspected. Per the workspace rule, no dependency may be added, removed, or altered without explicit user approval.

- `ash`, `ash_state_machine`, `ecto_sqlite3`, `stream_data`, and `wasmex` are already present.
- `ash_sqlite` is NOT present. It is required for the Ash SQLite data layer. The user has APPROVED adding it with an exact pinned version during implementation.
- `ash_paper_trail` is NOT present. It is required for the Execution version history. The user has APPROVED adding it with an exact pinned version during implementation.
- Approval covers only `ash_sqlite` and `ash_paper_trail`. Any other new dependency still requires explicit user approval.
- After adding the approved dependencies, `mix usage_rules.sync --yes` is run so the Ash skill stays up to date.
- `Task.Supervisor` is part of Elixir and needs no dependency.

## Glossary

- **Sandbox_Domain**: The Ash domain `ChimeraRuntime.Sandbox` that groups the Plugin and Execution resources.
- **Audit_Domain**: The Ash domain `ChimeraRuntime.Audit` that holds the AshPaperTrail-generated version resource for Execution.
- **Version_Resource**: The resource AshPaperTrail generates to store Execution version entries, registered in the Audit_Domain.
- **Fuel_Budget**: The finite amount of Wasmtime fuel set on a Wasmex store before a run, consumed as the module executes instructions.
- **Fuel_Exhaustion**: The Wasm trap raised by Wasmtime when the Fuel_Budget is fully consumed.
- **Plugin**: The Ash resource that stores a WebAssembly plugin definition (name, source code, compiled binary, timeout, lifecycle state).
- **Execution**: The Ash resource that records one run of a Plugin, with PaperTrail version history.
- **Engine**: The module `ChimeraRuntime.Runner.Engine` that runs Plugin binaries in isolation.
- **Worker**: An ephemeral, unlinked process started under the Task_Supervisor to run one Wasmex invocation.
- **Task_Supervisor**: The `Task.Supervisor` instance that supervises Workers.
- **Caller**: The process that invokes the Engine.
- **Deadline**: The Plugin `timeout_ms` value, in milliseconds, within which a Worker must complete.
- **Wasmex**: The WebAssembly runtime library, used with WASI disabled.
- **Lifecycle_State**: One of `:draft`, `:compiling`, `:active`, `:quarantined`.
- **Execution_Status**: One of `:success`, `:timeout`, `:error`.
- **Failure_Rate**: The count of Executions with status `:timeout` or `:error` divided by total Executions of a Plugin.
- **Test_Suite**: The ExUnitProperties test suite targeting the Engine.
- **Gravedigger**: The SRE verification flow that executes a single pre-promotion test run on a Plugin in `:compiling` before the Plugin is transitioned to `:active`.
- **Run_Mode**: The mode of an Engine run, one of `:standard` (default) or `:verification`. The `:verification` mode is used only by the Gravedigger.
- **Verification_Run**: An Engine run invoked with Run_Mode `:verification`.
- **Rogue_Module**: A malformed byte array, an invalid Wasm header, or a Wasm module containing an infinite loop.

## Requirements

### Requirement 1: Sandbox Domain

**User Story:** As a developer, I want an Ash domain for the sandbox, so that plugin and execution resources are organized and accessible through one API.

#### Acceptance Criteria

1. THE Sandbox_Domain SHALL be defined as the module `ChimeraRuntime.Sandbox`.
2. THE Sandbox_Domain SHALL register exactly two resources: the Plugin resource and the Execution resource.
3. WHEN the application starts, THE Sandbox_Domain and THE Audit_Domain SHALL both be listed in the application's `:ash_domains` configuration so that `ChimeraRuntime.Sandbox` and `ChimeraRuntime.Audit` are resolvable by Ash without a compilation or boot error.
4. THE Sandbox_Domain SHALL persist Plugin and Execution data in SQLite through the Ash SQLite data layer.
5. WHEN the database migrations are run against an empty SQLite database, THE Sandbox_Domain SHALL create one table for the Plugin resource and one table for the Execution resource, and THE Audit_Domain SHALL create one table for the Version_Resource, with each table containing a column for every persisted attribute of its resource.
6. IF a migration fails while creating the Plugin or Execution table, THEN THE Sandbox_Domain SHALL halt the migration run, report an error identifying the failed migration, and leave no partially created table in the database.
7. WHEN a Plugin or Execution record is created through the Sandbox_Domain and the application is then restarted, THE Sandbox_Domain SHALL return that record with all persisted attribute values unchanged.
8. THE Audit_Domain SHALL be defined as the module `ChimeraRuntime.Audit` and SHALL register exactly one resource: the Version_Resource generated by AshPaperTrail for Execution.
9. THE Execution SHALL route its AshPaperTrail Version_Resource into the Audit_Domain, such that the Sandbox_Domain registers no Version_Resource.

### Requirement 2: Plugin Resource Attributes

**User Story:** As a developer, I want to store plugin definitions, so that the Engine can load and run them.

#### Acceptance Criteria

1. THE Plugin SHALL store a required `name` attribute of type string with a length of 1 to 255 characters.
2. THE Plugin SHALL store an optional `source_code` attribute of type string with a maximum size of 1,048,576 bytes (1 MiB).
3. THE Plugin SHALL store an optional `wasm_binary` attribute of type binary with a maximum size of 10,485,760 bytes (10 MiB).
4. THE Plugin SHALL store a `timeout_ms` attribute of type integer with a default value of 500 and an allowed range of 1 to 600,000 inclusive.
5. IF a Plugin is created or updated with a `timeout_ms` value less than 1 or greater than 600,000, THEN THE Plugin SHALL reject the change with a validation error identifying `timeout_ms` as invalid, and THE Plugin SHALL leave the previously stored record unchanged.
6. WHEN a Plugin is created or updated with a `name` that exactly matches (case-sensitive) the `name` of another stored Plugin, THE Plugin SHALL reject the change with a validation error identifying `name` as already taken, and THE Plugin SHALL leave the previously stored record unchanged.
7. IF a Plugin is created or updated with a `name` that is absent, null, or an empty string, THEN THE Plugin SHALL reject the change with a validation error identifying `name` as required, and THE Plugin SHALL leave the previously stored record unchanged.
8. IF a Plugin is created or updated with a `name`, `source_code`, or `wasm_binary` value that exceeds its maximum length or size, or with a `timeout_ms` value that is not an integer, THEN THE Plugin SHALL reject the change with a validation error identifying the offending attribute, and THE Plugin SHALL leave the previously stored record unchanged.
9. THE Plugin SHALL store a `verification_used` attribute of type boolean with a default value of false, marking whether the single Verification_Run of the Plugin has been consumed.

### Requirement 3: Plugin Lifecycle State Machine

**User Story:** As a developer, I want plugin lifecycle states enforced, so that only validated plugins run and faulty plugins are isolated.

#### Acceptance Criteria

1. THE Plugin SHALL use AshStateMachine with exactly four Lifecycle_State values: `:draft`, `:compiling`, `:active`, and `:quarantined`.
2. WHEN a Plugin is created, THE Plugin SHALL set its Lifecycle_State to `:draft`.
3. WHEN the compile action is invoked on a Plugin in `:draft`, THE Plugin SHALL transition its Lifecycle_State to `:compiling`.
4. WHEN the activate action is invoked on a Plugin in `:compiling` whose `wasm_binary` is a non-empty binary, THE Plugin SHALL transition its Lifecycle_State to `:active`.
5. WHEN the quarantine action is invoked on a Plugin in `:draft`, `:compiling`, or `:active`, THE Plugin SHALL transition its Lifecycle_State to `:quarantined`.
6. IF a transition is requested that is not defined for the current Lifecycle_State (including any action invoked on a Plugin in `:quarantined`, compile invoked on a Plugin not in `:draft`, or activate invoked on a Plugin not in `:compiling`), THEN THE Plugin SHALL reject the action with an error identifying the current Lifecycle_State and the requested action, and SHALL keep the Lifecycle_State and all other attributes unchanged.
7. IF the activate action is invoked on a Plugin whose `wasm_binary` is nil or an empty binary (zero bytes), THEN THE Plugin SHALL reject the action with a validation error indicating that `wasm_binary` is required, and SHALL keep the Lifecycle_State unchanged.
8. IF a state-changing action fails for any reason, THEN THE Plugin SHALL persist no change to its Lifecycle_State.
9. WHEN the activate action is invoked on a Plugin in `:compiling` whose `wasm_binary` is a non-empty binary, THE Plugin SHALL transition to `:active` regardless of whether `verification_used` is true or false.
10. WHEN a Verification_Run completes with any result, THE Plugin SHALL keep its Lifecycle_State unchanged by that run.

### Requirement 4: Execution Resource and Audit History

**User Story:** As an operator, I want every run recorded with history, so that I can audit plugin behavior.

#### Acceptance Criteria

1. THE Execution SHALL belong to exactly one Plugin.
2. IF an Execution is created without a Plugin reference or with a Plugin reference that does not exist, THEN THE Execution SHALL reject the create, return a validation error identifying the Plugin relationship, and persist no Execution record.
3. THE Execution SHALL store `input_json` and `output_json` attributes of type map.
4. WHEN an Execution is created with a nil `output_json`, THE Execution SHALL persist the record with `output_json` as nil.
5. THE Execution SHALL store a required `duration_ms` attribute of type integer with a minimum value of 0 and a maximum value of 2,147,483,647.
6. IF `duration_ms` is nil, negative, non-integer, or greater than 2,147,483,647, THEN THE Execution SHALL reject the create or update, return a validation error identifying `duration_ms`, and leave the stored record unchanged.
7. THE Execution SHALL store a required `status` attribute constrained to the Execution_Status values `:success`, `:timeout`, and `:error`.
8. IF `status` is nil or is not one of `:success`, `:timeout`, or `:error`, THEN THE Execution SHALL reject the create or update, return a validation error identifying `status`, and leave the stored record unchanged.
9. THE Execution SHALL store an `error_reason` attribute of type string with a maximum length of 2,000 characters.
10. WHEN an Execution is created or updated, THE Execution SHALL record exactly one version entry through AshPaperTrail for that action, containing the changed attribute values.
11. WHEN an Execution has status `:success`, THE Execution SHALL have a nil `error_reason`.
12. WHEN an Execution has status `:timeout` or `:error`, THE Execution SHALL have an `error_reason` containing at least 1 non-whitespace character.
13. IF an Execution violates the `error_reason` rule for its `status`, THEN THE Execution SHALL reject the create or update, return a validation error identifying `error_reason`, persist no new version entry, and leave the stored record unchanged.
14. THE Execution SHALL store a required `run_mode` attribute constrained to the Run_Mode values `:standard` and `:verification`, with a default value of `:standard`.
15. IF `run_mode` is nil or is not one of `:standard` or `:verification`, THEN THE Execution SHALL reject the create or update, return a validation error identifying `run_mode`, and leave the stored record unchanged.

### Requirement 5: Plugin Aggregates

**User Story:** As an operator, I want per-plugin run statistics, so that I can identify unreliable plugins.

#### Acceptance Criteria

1. THE Plugin SHALL expose a `total_runs` aggregate equal to the count of all Executions belonging to that Plugin, regardless of Execution status, as a non-negative integer.
2. THE Plugin SHALL expose an `avg_duration_ms` aggregate equal to the arithmetic mean of `duration_ms` across the Executions of that Plugin that have a non-nil `duration_ms`, expressed in milliseconds as a number.
3. THE Plugin SHALL expose a `failure_rate` value equal to the number of failed Executions (status `:timeout` or `:error`) of that Plugin divided by `total_runs`, as a float.
4. WHEN a Plugin has zero Executions, THE Plugin SHALL report `total_runs` as 0 and `failure_rate` as 0.0.
5. WHEN a Plugin has zero Executions, THE Plugin SHALL report `avg_duration_ms` as nil.
6. WHEN a Plugin has at least one Execution and none of its Executions has a non-nil `duration_ms`, THE Plugin SHALL report `avg_duration_ms` as nil.
7. FOR ALL sets of Executions of a Plugin, THE Plugin SHALL report a `failure_rate` between 0.0 and 1.0 inclusive.
8. WHEN an Execution is created or its status changes, THE Plugin SHALL reflect the updated `total_runs`, `avg_duration_ms`, and `failure_rate` values on the next read of the Plugin.
9. THE Plugin SHALL include Executions with `run_mode` `:verification` in `total_runs`, `avg_duration_ms`, and `failure_rate`, in the same way as Executions with `run_mode` `:standard`.

### Requirement 6: Worker Isolation

**User Story:** As a platform engineer, I want each Wasm run isolated in its own process, so that a faulty module cannot affect the host.

#### Acceptance Criteria

1. WHEN the Engine runs a Plugin, THE Engine SHALL start exactly one new Worker under the Task_Supervisor for that run, and SHALL NOT reuse a Worker from any previous run.
2. THE Engine SHALL start the Worker without linking the Worker to the Caller, such that termination of the Worker with any exit reason (including `:kill`) does not terminate the Caller process.
3. WHEN the application starts, THE Application SHALL start the Task_Supervisor in the application supervision tree before the Engine accepts its first run request.
4. WHEN a run completes successfully, THE Engine SHALL ensure the Worker process for that run is no longer alive within 1000 milliseconds of returning the result to the Caller.
5. WHEN a run times out, THE Engine SHALL terminate the Worker process for that run and SHALL ensure it is no longer alive within 1000 milliseconds of returning the timeout error to the Caller.
6. IF a run fails because the Wasm module traps, crashes the Worker, or returns an error, THEN THE Engine SHALL return an error result to the Caller, SHALL ensure the Worker process for that run is no longer alive within 1000 milliseconds, and SHALL keep the Caller and Task_Supervisor processes alive.
7. THE Engine SHALL instantiate Wasmex with WASI disabled (`wasi: false`).
8. THE Engine SHALL provide the Wasm module with an empty set of host imports, no filesystem access, and no network access, such that any import the module declares causes instantiation to fail.
9. IF the Wasm module declares an import that the Engine does not provide, THEN THE Engine SHALL return an error result to the Caller indicating an unsatisfied import, SHALL NOT execute any module code, and SHALL ensure the Worker process for that run is no longer alive within 1000 milliseconds.
10. BEFORE the Engine is implemented, THE implementation process SHALL verify directly from the installed dependency source in `deps/wasmex` (version 0.16.0) the option shapes of `Wasmex.start_link/1`, `Wasmex.Pipe`, WASI configuration, and fuel and epoch configuration (including `Wasmex.EngineConfig`, `Wasmex.Engine`, `Wasmex.Store`, and `Wasmex.StoreOrCaller.set_fuel/2`).
11. THE Engine SHALL pass to Wasmex only options that the verification in criterion 10 confirmed to exist in Wasmex 0.16.0.
12. IF an option required by this specification is not confirmed to exist in Wasmex 0.16.0, THEN THE implementation process SHALL stop work that depends on that option and report the gap to the user without altering `mix.exs`.

### Requirement 7: Deadline Enforcement

**User Story:** As a platform engineer, I want strict time limits, so that infinite loops cannot hold resources.

#### Acceptance Criteria

1. WHEN the Engine starts a Worker for a Plugin, THE Engine SHALL wait for the Worker result for at most the Plugin `timeout_ms` (an integer from 1 to 600000 milliseconds) using `Task.yield`.
2. IF the Plugin `timeout_ms` is missing, not an integer, or outside the range 1 to 600000, THEN THE Engine SHALL return `{:error, :invalid_timeout}` to the Caller without starting a Worker.
3. IF the Worker does not return within the Deadline, THEN THE Engine SHALL terminate the Worker with `Task.shutdown(task, :brutal_kill)`.
4. IF the Worker does not return within the Deadline, THEN THE Engine SHALL return `{:error, :timeout}` to the Caller.
5. WHEN a Worker is terminated for exceeding the Deadline, THE Engine SHALL return control to the Caller within the Deadline plus 100 ms.
6. WHEN the Worker returns before the Deadline, THE Engine SHALL return the Worker result to the Caller within 10 ms of the Worker producing it, without waiting for the Deadline to elapse.
7. IF `Task.shutdown(task, :brutal_kill)` returns a Worker result instead of terminating the Worker because the Worker completed during shutdown, THEN THE Engine SHALL return that Worker result to the Caller instead of `{:error, :timeout}`.
8. THE Engine SHALL create every Wasmex engine with fuel consumption enabled (`consume_fuel: true`) and SHALL set a finite, positive Fuel_Budget on the Wasmex store of every run before invoking any exported function.
9. WHERE the installed Wasmex does not support fuel consumption, THE Engine SHALL use epoch interruption to interrupt module execution inside Wasmtime, and SHALL satisfy criteria 10 to 12 with epoch interruption in place of fuel.
10. WHEN a run ends with Fuel_Exhaustion, THE Engine SHALL return `{:error, reason}` where `reason` is a tuple whose first element is `:fuel_exhausted`.
11. WHEN a run ends with Fuel_Exhaustion, THE Engine SHALL record the run as status `:timeout` (see Requirement 9, criterion 10).
12. WHEN a run ends with Fuel_Exhaustion or at the Deadline, THE Engine SHALL leave no Wasmtime instance executing module code, such that a subsequent Engine run on a valid Plugin completes within its own Deadline.
13. THE Engine SHALL treat the BEAM Deadline of criterion 3 as the authoritative backstop, and SHALL apply it to every run whether or not the Fuel_Budget has been exhausted.

### Requirement 8: Failure Containment

**User Story:** As a platform engineer, I want all failures contained, so that the Caller never crashes from plugin behavior.

#### Acceptance Criteria

1. IF the Worker exits abnormally (any exit reason other than `:normal`, including crash, kill, or timeout-triggered shutdown), THEN THE Engine SHALL trap the exit, return `{:error, reason}` to the Caller within 500 milliseconds of the exit signal, and leave the Caller process alive.
2. IF Wasmex fails to compile or instantiate the module (including invalid Wasm bytes, unresolved imports, or an instantiation error), THEN THE Engine SHALL return `{:error, reason}` where `reason` identifies the failure as a compile or instantiation failure, and start no further Worker for that invocation.
3. IF the requested exported function does not exist in the module, THEN THE Engine SHALL return `{:error, reason}` where `reason` contains the requested function name and indicates a missing export.
4. IF a Wasm trap occurs during execution (for example unreachable instruction, out-of-bounds memory access, or integer divide by zero), THEN THE Engine SHALL return `{:error, reason}` where `reason` indicates a trap, and discard any partial results from that invocation.
5. IF any failure described in criteria 1 to 4 occurs, THEN THE Engine SHALL keep the Caller process alive, terminate the Worker if it is still running, and leave zero Worker-originated messages (including `:DOWN` and `:EXIT` messages) in the Caller mailbox once the `{:error, reason}` result is returned.
6. IF the Run_Mode is `:standard` and the Plugin Lifecycle_State is not `:active`, THEN THE Engine SHALL return `{:error, :plugin_not_active}`, start zero Workers, and leave the Plugin record unchanged.
7. IF the Plugin has a nil `wasm_binary` and the Plugin Lifecycle_State is permitted for the Run_Mode, THEN THE Engine SHALL return `{:error, :missing_binary}`, start zero Workers, and leave the Plugin record unchanged.
8. IF the Plugin Lifecycle_State is not permitted for the Run_Mode AND the Plugin has a nil `wasm_binary`, THEN THE Engine SHALL return `{:error, :plugin_not_active}`.
9. IF the Run_Mode is `:verification` and the Plugin Lifecycle_State is not `:compiling` (including `:draft`, `:active`, and `:quarantined`), THEN THE Engine SHALL return `{:error, :plugin_not_active}`, start zero Workers, and leave the Plugin record unchanged.
10. IF the Run_Mode is `:verification`, the Plugin Lifecycle_State is `:compiling`, and `verification_used` is true, THEN THE Engine SHALL return `{:error, :verification_already_used}`, start zero Workers, and leave the Plugin record unchanged.
11. WHEN the Run_Mode is `:verification`, the Plugin Lifecycle_State is `:compiling`, `verification_used` is false, and the Plugin has a non-nil `wasm_binary`, THE Engine SHALL set `verification_used` to true on the Plugin from the Caller process immediately before starting the Worker, so that the one-shot is consumed when the Worker starts.
12. IF the Engine fails to persist `verification_used` as true, THEN THE Engine SHALL return `{:error, :verification_marker_failed}` and start zero Workers.
13. WHEN a Verification_Run completes with any result, THE Engine SHALL leave `verification_used` true and the Plugin Lifecycle_State unchanged.

### Requirement 9: Execution Persistence

**User Story:** As an operator, I want every run persisted, so that statistics and audits are complete.

#### Acceptance Criteria

1. WHEN a Worker run finishes with a result, THE Engine SHALL create an Execution with status `:success`, the `run_mode` of the run, the input, the output, and the measured `duration_ms` as a non-negative integer number of milliseconds.
2. WHEN a run is terminated at the Deadline, THE Engine SHALL create an Execution with status `:timeout`, the input, a `duration_ms` value, and an `error_reason` that is a non-empty string of at most 1,000 characters indicating the Deadline was exceeded.
3. IF a run fails for any reason other than the Deadline after a Worker has started, THEN THE Engine SHALL create an Execution with status `:error`, the input, a `duration_ms` value, and an `error_reason` that is a non-empty string of at most 1,000 characters describing the failure cause.
4. THE Engine SHALL persist each Execution from the Caller process, not from the Worker process.
5. THE Engine SHALL measure `duration_ms` using a monotonic clock, from the moment the Worker is started until the moment the result, failure, or Deadline termination is observed.
6. IF persisting the Execution fails, THEN THE Engine SHALL log one error entry that identifies the persistence failure and the Plugin, SHALL return the run result to the Caller unchanged, and SHALL NOT retry the persistence.
7. WHEN the Engine creates an Execution, THE Engine SHALL relate the Execution to the Plugin that was run.
8. IF a run fails before a Worker has started, THEN THE Engine SHALL return the failure to the Caller and SHALL NOT create an Execution.
9. THE Engine SHALL set the `run_mode` of every Execution it creates (including `:timeout` and `:error` Executions) to the Run_Mode of the run.
10. WHEN a run ends with Fuel_Exhaustion, THE Engine SHALL create an Execution with status `:timeout` and an `error_reason` that is a non-empty string of at most 1,000 characters indicating fuel exhaustion.

### Requirement 10: Engine Result Contract

**User Story:** As a developer, I want a consistent return contract, so that callers can pattern match on outcomes.

#### Acceptance Criteria

1. THE Engine SHALL expose a function that accepts a Plugin, an exported function name (a binary of 1 to 255 bytes), a list of arguments (0 to 64 elements), and an optional Run_Mode option that defaults to `:standard`.
2. WHEN a run completes successfully, THE Engine SHALL return a two-element tuple `{:ok, output}`, where `output` is the list of values returned by the exported function (an empty list if the function returns no values).
3. WHEN a run fails, THE Engine SHALL return a two-element tuple `{:error, reason}`, where `reason` is an atom or a tuple whose first element is an atom identifying the failure category.
4. IF the Plugin is invalid, the exported function name is not a binary of 1 to 255 bytes, the arguments are not a list of 0 to 64 elements, or the Run_Mode is not `:standard` or `:verification`, THEN THE Engine SHALL return `{:error, reason}` with `reason` identifying invalid input, without starting execution.
5. IF the Wasmex runtime raises, exits, or throws during a run, THEN THE Engine SHALL catch it and return `{:error, reason}` with `reason` identifying a runtime failure, and no exception, exit, or throw SHALL reach the Caller.
6. THE Engine SHALL return exactly one result tuple, either `{:ok, output}` or `{:error, reason}`, for every input, including inputs of an invalid type.

### Requirement 11: Property-Based Test Suite

**User Story:** As a maintainer, I want property tests that attack the Engine, so that isolation guarantees are proven under hostile input.

#### Acceptance Criteria

1. THE Test_Suite SHALL use ExUnitProperties with StreamData generators.
2. THE Test_Suite SHALL include a property that generates byte arrays of 0 to 4096 bytes as Plugin binaries and asserts that, for every generated input, the Engine returns `{:error, reason}` and the Caller process remains alive.
3. THE Test_Suite SHALL include a property that generates byte arrays consisting of the Wasm magic header (`\0asm`) followed by 0 to 4096 random bytes and asserts that, for every generated input, the Engine returns `{:error, reason}` and the Caller process remains alive.
4. THE Test_Suite SHALL include a property that generates byte arrays of 0 to 4096 bytes whose first 4 bytes differ from `\0asm` (including inputs shorter than 4 bytes) and asserts that, for every generated input, the Engine returns `{:error, reason}` and the Caller process remains alive.
5. THE Test_Suite SHALL include a property that runs an infinite-loop Wasm module with generated `timeout_ms` values from 10 to 500 and asserts that, for every generated value, the Engine returns `{:error, :timeout}` within `timeout_ms` plus 100 ms, measured from the Engine call to its return.
6. FOR ALL Rogue_Module inputs, THE Test_Suite SHALL assert that the Caller process is alive, as reported by `Process.alive?/1`, after the Engine returns.
7. FOR ALL Rogue_Module inputs, THE Test_Suite SHALL assert that the Task_Supervisor has 0 Worker children within 100 ms after the Engine returns.
8. FOR ALL Rogue_Module inputs, IF the Engine call started a Worker, THEN THE Test_Suite SHALL assert that the persisted Execution count for that call increases by exactly 1.
9. FOR ALL Rogue_Module inputs, IF the Engine call did not start a Worker, THEN THE Test_Suite SHALL assert that the persisted Execution count does not change.
10. THE Test_Suite SHALL include a property that generates sequences of 0 to 50 Executions with mixed success and failure outcomes and asserts that `failure_rate` is a number greater than or equal to 0.0 and less than or equal to 1.0 for every sequence, including the empty sequence.
11. THE Test_Suite SHALL include an example-based test in which a valid Wasm module is executed and the Engine returns `{:ok, output}`, with `output` equal to the module's known expected value.
12. THE Test_Suite SHALL include example-based tests that exercise every valid Plugin state machine transition and assert the resulting state, and at least one test per invalid transition that asserts the transition is rejected with an error and the Plugin state is unchanged.
13. THE Test_Suite SHALL run each property for a minimum of 100 iterations, except the infinite-loop property, which SHALL run a minimum of 20 iterations.
14. THE Test_Suite SHALL include example-based tests in which, for a valid Wasm Plugin in `:compiling` with `verification_used` false: a Verification_Run returns `{:ok, output}` with the known expected value and creates one Execution with `run_mode` `:verification`; a second Verification_Run on the same Plugin returns `{:error, :verification_already_used}` and creates no Execution; and a `:standard` run on a Plugin in `:compiling` returns `{:error, :plugin_not_active}` and creates no Execution.
15. THE Test_Suite SHALL include example-based tests asserting that a Verification_Run on a Plugin in `:draft`, `:active`, or `:quarantined` returns `{:error, :plugin_not_active}`, and that the activate action still succeeds on a `:compiling` Plugin after its Verification_Run, leaving the Plugin Lifecycle_State unchanged by the Verification_Run itself.
16. THE Test_Suite SHALL assert, in the infinite-loop property for every generated `timeout_ms`, that after the Engine returns, a follow-up Engine run of a valid Wasm Plugin returns `{:ok, output}` within 500 ms, evidencing that no native Wasmtime instance remains spinning.
17. THE Test_Suite SHALL include an example-based test in which an infinite-loop Wasm module with a small Fuel_Budget returns `{:error, reason}` with `reason` identifying `:fuel_exhausted`, and creates one Execution with status `:timeout`.
18. THE Test_Suite SHALL include an example-based test asserting that the Engine sets a finite Fuel_Budget on the store of every run.
19. THE Test_Suite SHALL include an example-based test asserting that the Version_Resource is registered in the Audit_Domain and that creating an Execution creates exactly one entry in it.

### Requirement 12: Dependency Governance

**User Story:** As a project owner, I want control over dependency changes, so that the dependency lock stays intact.

#### Acceptance Criteria

1. THE Phase 1 implementation SHALL use Wasmex, with WASI disabled, as the only WebAssembly runtime.
2. THE Phase 1 implementation SHALL leave every existing dependency entry in `mix.exs` unchanged, with no entry removed, commented out, or altered in name, version requirement, or options.
3. THE implementation process SHALL treat user approval as granted for adding exactly two dependencies, `ash_sqlite` and `ash_paper_trail`, to `mix.exs`.
4. IF any dependency other than `ash_sqlite` or `ash_paper_trail` is required and absent from `mix.exs`, THEN THE implementation process SHALL stop work that depends on the missing dependency, request explicit user approval naming the dependency, and leave `mix.exs` unmodified until the user responds.
5. IF the user denies or does not respond to a dependency approval request, THEN THE implementation process SHALL leave `mix.exs` unmodified and report the dependent work as blocked.
6. WHEN adding `ash_sqlite` or `ash_paper_trail` to `mix.exs`, THE implementation process SHALL add each with an exact pinned version requirement (for example `"== 1.2.3"`), and SHALL leave all other `mix.exs` entries unchanged.
7. WHEN `ash_sqlite` and `ash_paper_trail` have been added to `mix.exs`, THE implementation process SHALL run `mix usage_rules.sync --yes` so that the Ash skill stays up to date.
