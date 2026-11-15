defmodule ChimeraRuntimeWeb.ControlRoom.Refresh do
  @moduledoc """
  Pure coalescing decision for Control_Room registry refreshes.

  The LiveView keeps a timer reference in its `:refresh_ref` assign. When an
  Execution_Event or Plugin_Event arrives, `on_event/2` says whether a new
  refresh must be scheduled (no timer pending) or one is already scheduled.
  """

  @spec on_event(reference() | nil, pos_integer()) ::
          {:schedule, pos_integer()} | :already_scheduled
  def on_event(nil, delay_ms) when is_integer(delay_ms) and delay_ms > 0,
    do: {:schedule, delay_ms}

  def on_event(_ref, delay_ms) when is_integer(delay_ms) and delay_ms > 0,
    do: :already_scheduled
end
