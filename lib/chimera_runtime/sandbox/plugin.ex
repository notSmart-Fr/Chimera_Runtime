defmodule ChimeraRuntime.Sandbox.Plugin do
  @moduledoc """
  A stored WebAssembly plugin with a lifecycle managed by `AshStateMachine`.

  Lifecycle: `:draft -> :compiling -> :active`, with `:quarantined` reachable
  from any of the three live states.
  """

  use Ash.Resource,
    domain: ChimeraRuntime.Sandbox,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine],
    notifiers: [Ash.Notifier.PubSub]

  sqlite do
    table "plugins"
    repo(ChimeraRuntime.Repo)
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :compile, from: :draft, to: :compiling
      transition :activate, from: :compiling, to: :active
      transition :quarantine, from: [:draft, :compiling, :active], to: :quarantined
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :source_code, :wasm_binary, :timeout_ms]

      validate {ChimeraRuntime.Sandbox.Validations.MaxBytes,
                attribute: :source_code, max: 1_048_576}

      validate {ChimeraRuntime.Sandbox.Validations.MaxBytes,
                attribute: :wasm_binary, max: 10_485_760}
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :source_code, :wasm_binary, :timeout_ms]

      validate {ChimeraRuntime.Sandbox.Validations.MaxBytes,
                attribute: :source_code, max: 1_048_576}

      validate {ChimeraRuntime.Sandbox.Validations.MaxBytes,
                attribute: :wasm_binary, max: 10_485_760}
    end

    update :compile do
      require_atomic? false
      accept []
      change transition_state(:compiling)
    end

    update :activate do
      require_atomic? false
      accept []

      validate fn changeset, _context ->
        case changeset.data.wasm_binary do
          binary when is_binary(binary) and byte_size(binary) > 0 ->
            :ok

          _ ->
            {:error, field: :wasm_binary, message: "is required"}
        end
      end

      change transition_state(:active)
    end

    update :quarantine do
      require_atomic? false
      accept []
      change transition_state(:quarantined)
    end

    update :mark_verification_used do
      description "Internal one-shot marker. Succeeds only while verification_used is false."
      accept []
      change filter(expr(verification_used == false))
      change atomic_update(:verification_used, true)
    end

    action :run, :map do
      description "Run an active plugin function through the Engine (standard mode)."

      argument :id, :uuid, allow_nil?: false

      argument :function_name, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 255, allow_empty?: false]

      argument :args, {:array, ChimeraRuntime.Sandbox.Types.WasmNumber},
        allow_nil?: false,
        default: [],
        constraints: [min_length: 0, max_length: 64]

      run ChimeraRuntime.Sandbox.Plugin.Run
    end
  end

  pub_sub do
    module ChimeraRuntimeWeb.Endpoint
    prefix "sandbox"

    publish :create, "plugins",
      event: "plugin_changed",
      transform: &ChimeraRuntime.Sandbox.EventPayload.plugin/1

    publish :update, "plugins",
      event: "plugin_changed",
      transform: &ChimeraRuntime.Sandbox.EventPayload.plugin/1

    publish :compile, "plugins",
      event: "plugin_changed",
      transform: &ChimeraRuntime.Sandbox.EventPayload.plugin/1

    publish :activate, "plugins",
      event: "plugin_changed",
      transform: &ChimeraRuntime.Sandbox.EventPayload.plugin/1

    publish :quarantine, "plugins",
      event: "plugin_changed",
      transform: &ChimeraRuntime.Sandbox.EventPayload.plugin/1
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, allow_empty?: false
    end

    attribute :source_code, :string do
      public? true
    end

    attribute :wasm_binary, :binary do
      public? true
    end

    attribute :timeout_ms, :integer do
      allow_nil? false
      public? true
      default 500
      constraints min: 1, max: 600_000
    end

    attribute :verification_used, :boolean do
      allow_nil? false
      default false
      public? false
      writable? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :executions, ChimeraRuntime.Sandbox.Execution do
      destination_attribute :plugin_id
      public? true
    end
  end

  calculations do
    calculate :failure_rate,
              :float,
              expr(
                if total_runs == 0 do
                  0.0
                else
                  type(failed_runs, :float) / type(total_runs, :float)
                end
              ) do
      public? true
    end
  end

  aggregates do
    count :total_runs, :executions do
      public? true
    end

    avg :avg_duration_ms, :executions, :duration_ms do
      public? true
    end

    count :failed_runs, :executions do
      public? false
      filter expr(status in [:timeout, :error])
    end
  end

  identities do
    identity :unique_name, [:name], message: "has already been taken"
  end
end
