defmodule ChimeraRuntime.Sandbox.Validations.ErrorReasonMatchesStatus do
  @moduledoc """
  Ensures `error_reason` agrees with `status`.

  * `:success` requires a nil `error_reason`.
  * `:timeout` and `:error` require a non-blank `error_reason`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status)
    error_reason = Ash.Changeset.get_attribute(changeset, :error_reason)

    check(status, error_reason)
  end

  defp check(:success, nil), do: :ok

  defp check(:success, _reason),
    do: {:error, field: :error_reason, message: "must be nil when status is success"}

  defp check(status, reason) when status in [:timeout, :error] do
    if is_binary(reason) and String.trim(reason) != "" do
      :ok
    else
      {:error, field: :error_reason, message: "must be present when status is #{status}"}
    end
  end

  # nil/unknown status is reported by the attribute's own constraints.
  defp check(_status, _reason), do: :ok
end
