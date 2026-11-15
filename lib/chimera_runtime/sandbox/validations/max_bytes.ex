defmodule ChimeraRuntime.Sandbox.Validations.MaxBytes do
  @moduledoc "Validates that a binary attribute is at most `:max` bytes."
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]) and is_integer(opts[:max]) do
      {:ok, opts}
    else
      {:error, "attribute and max are required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]
    max = opts[:max]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_binary(value) and byte_size(value) > max ->
        {:error, field: attribute, message: "must be at most #{max} bytes"}

      _ ->
        :ok
    end
  end

  @impl true
  def atomic?, do: false
end
