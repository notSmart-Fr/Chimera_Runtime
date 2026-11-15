defmodule ChimeraRuntime.Sandbox.EventPayload do
  @moduledoc """
  Builds and validates the PubSub payloads for Execution and Plugin events.

  Payloads never carry `input_json`, `output_json`, `wasm_binary`, or
  `source_code`. Builders accept an `Ash.Notifier.Notification` or a bare record.
  """

  alias Ash.Notifier.Notification

  @max_error_reason 200

  @execution_keys [:duration_ms, :error_reason, :id, :inserted_at, :plugin_id, :run_mode, :status]
  @plugin_keys [:action, :id, :name, :state, :updated_at]

  @doc "Builds the Execution_Event payload."
  @spec execution(Notification.t() | struct()) :: map()
  def execution(%Notification{data: record}), do: execution(record)

  def execution(record) do
    %{
      id: record.id,
      plugin_id: record.plugin_id,
      status: record.status,
      run_mode: record.run_mode,
      duration_ms: record.duration_ms,
      error_reason: truncate(record.error_reason),
      inserted_at: record.inserted_at
    }
  end

  @doc "Builds the Plugin_Event payload. `:action` is `nil` for a bare record."
  @spec plugin(Notification.t() | struct()) :: map()
  def plugin(%Notification{data: record, action: action}) do
    record |> plugin() |> Map.put(:action, action_name(action))
  end

  def plugin(record) do
    %{
      id: record.id,
      name: record.name,
      state: record.state,
      action: nil,
      updated_at: record.updated_at
    }
  end

  @doc "True when the payload has exactly the Execution contract's keys and value types."
  @spec valid_execution?(term()) :: boolean()
  def valid_execution?(%{} = payload) when not is_struct(payload) do
    exact_keys?(payload, @execution_keys) and
      id?(payload.id) and
      id?(payload.plugin_id) and
      is_atom(payload.status) and not is_nil(payload.status) and
      is_atom(payload.run_mode) and not is_nil(payload.run_mode) and
      (is_nil(payload.duration_ms) or is_integer(payload.duration_ms)) and
      error_reason?(payload.error_reason) and
      time?(payload.inserted_at)
  end

  def valid_execution?(_), do: false

  @doc "True when the payload has exactly the Plugin contract's keys and value types."
  @spec valid_plugin?(term()) :: boolean()
  def valid_plugin?(%{} = payload) when not is_struct(payload) do
    exact_keys?(payload, @plugin_keys) and
      id?(payload.id) and
      is_binary(payload.name) and
      is_atom(payload.state) and not is_nil(payload.state) and
      is_atom(payload.action) and
      time?(payload.updated_at)
  end

  def valid_plugin?(_), do: false

  defp truncate(nil), do: nil
  defp truncate(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_reason)

  defp action_name(%{name: name}), do: name
  defp action_name(_), do: nil

  defp exact_keys?(payload, keys), do: payload |> Map.keys() |> Enum.sort() == keys

  defp id?(value), do: is_binary(value)

  defp error_reason?(nil), do: true

  defp error_reason?(reason) when is_binary(reason),
    do: String.length(reason) <= @max_error_reason

  defp error_reason?(_), do: false

  defp time?(%DateTime{}), do: true
  defp time?(%NaiveDateTime{}), do: true
  defp time?(_), do: false
end
