defmodule ChimeraRuntimeWeb.ControlRoom.ArgsCodec do
  @moduledoc """
  Pure, total codec between JSON array text and a list of numbers, used by the
  Control Room console to pass arguments to a Plugin function.
  """

  @max_bytes 4096
  @max_elements 64

  @type kind :: :object | :string | :boolean | :null | :array | :number
  @type reason ::
          :too_large
          | :invalid_json
          | {:not_array, kind()}
          | {:too_many, non_neg_integer()}
          | {:bad_element, non_neg_integer(), kind()}

  @doc """
  Parses argument text into a list of at most 64 numbers. Never raises.
  """
  @spec parse(term()) :: {:ok, [number()]} | {:error, reason()}
  def parse(text) when is_binary(text) and byte_size(text) > @max_bytes,
    do: {:error, :too_large}

  def parse(text) when is_binary(text) do
    if blank?(text), do: {:ok, []}, else: decode(text)
  rescue
    _ -> {:error, :invalid_json}
  catch
    _, _ -> {:error, :invalid_json}
  end

  def parse(_other), do: {:error, :invalid_json}

  @doc """
  Encodes a list of finite numbers as JSON array text.
  """
  @spec print([number()]) :: String.t()
  def print(list) when is_list(list), do: Jason.encode!(list)

  defp blank?(text) do
    case :unicode.characters_to_binary(text) do
      bin when is_binary(bin) -> String.trim(bin) == ""
      _ -> false
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> validate(list)
      {:ok, other} -> {:error, {:not_array, kind(other)}}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate(list) do
    case length(list) do
      n when n > @max_elements -> {:error, {:too_many, n}}
      _ -> check_elements(list)
    end
  end

  defp check_elements(list) do
    list
    |> Enum.with_index()
    |> Enum.find(fn {el, _i} -> not is_number(el) end)
    |> case do
      nil -> {:ok, list}
      {el, index} -> {:error, {:bad_element, index, kind(el)}}
    end
  end

  defp kind(v) when is_map(v), do: :object
  defp kind(v) when is_binary(v), do: :string
  defp kind(v) when is_boolean(v), do: :boolean
  defp kind(nil), do: :null
  defp kind(v) when is_list(v), do: :array
  defp kind(v) when is_number(v), do: :number
end
