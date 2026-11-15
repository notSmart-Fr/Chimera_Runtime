defmodule ChimeraRuntime.Orchestration.StageError do
  @moduledoc """
  Plain struct (never raised) describing which publish saga stage failed and why.
  """

  @type stage :: :preflight | :compile | :verify | :promote

  @type t :: %__MODULE__{stage: stage(), reason: term()}

  @enforce_keys [:stage]
  defstruct [:stage, :reason]
end
