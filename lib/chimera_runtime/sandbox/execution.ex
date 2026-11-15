defmodule ChimeraRuntime.Sandbox.Execution do
  @moduledoc """
  A single recorded plugin run. Changes are audited with AshPaperTrail; the generated
  `ChimeraRuntime.Sandbox.Execution.Version` resource lives in the same domain
  (ash_paper_trail 0.8.1 cannot route it elsewhere and sets `validate_domain_inclusion?: false`).
  """
  use Ash.Resource,
    domain: ChimeraRuntime.Sandbox,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  sqlite do
    table "executions"
    repo(ChimeraRuntime.Repo)

    references do
      reference(:plugin, on_delete: :restrict)
    end
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :plugin_id,
        :input_json,
        :output_json,
        :duration_ms,
        :status,
        :error_reason,
        :run_mode
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :input_json,
        :output_json,
        :duration_ms,
        :status,
        :error_reason,
        :run_mode
      ]
    end
  end

  validations do
    validate ChimeraRuntime.Sandbox.Validations.ErrorReasonMatchesStatus,
      on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    attribute :input_json, :map, allow_nil?: true, public?: true

    attribute :output_json, :map, allow_nil?: true, public?: true

    attribute :duration_ms, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 2_147_483_647
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:success, :timeout, :error]
    end

    attribute :error_reason, :string do
      public? true
      constraints max_length: 2000, allow_empty?: true, trim?: false
    end

    attribute :run_mode, :atom do
      allow_nil? false
      public? true
      default :standard
      constraints one_of: [:standard, :verification]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin, ChimeraRuntime.Sandbox.Plugin do
      allow_nil? false
      public? true
      attribute_public? true
    end
  end
end
