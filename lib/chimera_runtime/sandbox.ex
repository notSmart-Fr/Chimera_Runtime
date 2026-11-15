defmodule ChimeraRuntime.Sandbox do
  @moduledoc """
  Ash domain for the Poltergeist Sandbox: stored WebAssembly plugins and their recorded executions.

  The AshPaperTrail-generated `ChimeraRuntime.Sandbox.Execution.Version` resource is registered
  here because ash_paper_trail 0.8.1 cannot route it to another domain.
  """
  use Ash.Domain

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
