defmodule ChimeraRuntime.Sandbox do
  @moduledoc """
  Ash domain for the Poltergeist Sandbox: stored WebAssembly plugins and their recorded executions.

  The AshPaperTrail-generated `ChimeraRuntime.Sandbox.Execution.Version` resource is registered
  here because ash_paper_trail 0.8.1 cannot route it to another domain.
  """
  use Ash.Domain, extensions: [AshAi]

  tools do
    tool(:list_plugins, ChimeraRuntime.Sandbox.Plugin, :read,
      description: "List plugins with health metrics. Never returns Wasm bytes or source code.",
      select: [:id, :name, :state, :timeout_ms, :inserted_at, :updated_at],
      load: [:total_runs, :failure_rate, :avg_duration_ms],
      filterable_fields: [:id, :name, :state],
      sortable_fields: [:name, :state, :total_runs, :failure_rate, :avg_duration_ms],
      aggregatable_fields: [],
      action_parameters: [:sort, :offset, :limit, :filter],
      annotations: [read_only_hint: true]
    )

    tool(:inspect_execution_metrics, ChimeraRuntime.Sandbox.Plugin, :read,
      description: "Run statistics for one plugin.",
      get_by: :id,
      select: [:id, :name, :state],
      load: [:total_runs, :failure_rate, :avg_duration_ms],
      annotations: [read_only_hint: true]
    )

    tool(:run_plugin, ChimeraRuntime.Sandbox.Plugin, :run,
      description: "Run an active plugin function in the sandbox (standard mode only).",
      annotations: [read_only_hint: false, open_world_hint: false]
    )

    tool(:quarantine_plugin, ChimeraRuntime.Sandbox.Plugin, :quarantine,
      description: "Quarantine a plugin so it can no longer run.",
      annotations: [destructive_hint: true]
    )
  end

  resources do
    resource ChimeraRuntime.Sandbox.Plugin do
      define :create_plugin, action: :create
      define :get_plugin, action: :read, get_by: [:id]
      define :compile_plugin, action: :compile
      define :activate_plugin, action: :activate
      define :quarantine_plugin, action: :quarantine
      define :mark_verification_used, action: :mark_verification_used
    end

    resource ChimeraRuntime.Sandbox.Execution do
      define :create_execution, action: :create
      define :list_executions, action: :read
    end

    resource ChimeraRuntime.Sandbox.Execution.Version do
      define :list_execution_versions, action: :read
    end
  end
end
