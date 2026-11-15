defmodule ChimeraRuntimeWeb.ControlRoom.Format do
  @moduledoc """
  Pure formatters for the Control Room.

  `duration/1` and `parse_duration/1` use integer arithmetic so the round trip is exact.
  """

  @units ["B", "KiB", "MiB", "GiB", "TiB"]
  @max_unit_index length(@units) - 1

  @doc """
  Formats a duration in microseconds: `"412 µs"` below 1000, otherwise `"12.345 ms"`.
  """
  @spec duration(non_neg_integer()) :: String.t()
  def duration(us) when is_integer(us) and us >= 0 and us < 1000, do: "#{us} µs"

  def duration(us) when is_integer(us) and us >= 1000 do
    frac = us |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{div(us, 1000)}.#{frac} ms"
  end

  @doc """
  Inverse of `duration/1`. Returns the microsecond integer, or `:error` for unrecognised text.
  """
  @spec parse_duration(String.t()) :: non_neg_integer() | :error
  def parse_duration(text) when is_binary(text) do
    case Regex.run(~r/\A(\d+) µs\z/u, text) do
      [_, us] ->
        String.to_integer(us)

      nil ->
        case Regex.run(~r/\A(\d+)\.(\d{3}) ms\z/, text) do
          [_, ms, frac] -> String.to_integer(ms) * 1000 + String.to_integer(frac)
          nil -> :error
        end
    end
  end

  def parse_duration(_), do: :error

  @doc """
  Formats a byte count with binary units (B, KiB, MiB, GiB, TiB), e.g. `"1.5 MiB"`.
  """
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) when is_integer(n) and n >= 0, do: bytes(n, 0)

  defp bytes(n, 0) when n < 1024, do: "#{n} B"
  defp bytes(n, 0), do: scale(n / 1024, 1)

  defp scale(value, idx) do
    rounded = Float.round(value, 1)

    if rounded < 1024 or idx == @max_unit_index do
      "#{format_float(value, 1)} #{Enum.at(@units, idx)}"
    else
      scale(value / 1024, idx + 1)
    end
  end

  @doc """
  Formats a fraction (0.0 to 1.0) as a percentage with one decimal, e.g. `0.125` -> `"12.5%"`.
  """
  @spec percent(number() | nil) :: String.t()
  def percent(nil), do: "0.0%"
  def percent(fraction) when is_number(fraction), do: "#{format_float(fraction * 100, 1)}%"

  @doc """
  Formats an average duration in milliseconds with up to three decimals, or `"n/a"` for nil.
  """
  @spec avg_ms(number() | Decimal.t() | nil) :: String.t()
  def avg_ms(nil), do: "n/a"
  def avg_ms(%Decimal{} = d), do: d |> Decimal.to_float() |> avg_ms()

  def avg_ms(value) when is_number(value) do
    value
    |> format_float(3)
    |> String.replace(~r/(\.\d*?)0+\z/, "\\1")
    |> String.replace_suffix(".", "")
  end

  defp format_float(value, decimals), do: :erlang.float_to_binary(value * 1.0, decimals: decimals)
end
