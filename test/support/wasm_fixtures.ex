defmodule ChimeraRuntime.WasmFixtures do
  @moduledoc """
  Hand-assembled WebAssembly modules for tests.

  Each fixture is a checked-in byte literal. No WAT compiler is involved.
  Section layout: `<<id, size, contents...>>`; all sizes are single-byte LEB128.
  """

  @header <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  @doc "Exports `add(i32, i32) -> i32`."
  @spec add() :: binary()
  def add do
    @header <>
      <<
        # type: (i32, i32) -> i32
        0x01,
        0x07,
        0x01,
        0x60,
        0x02,
        0x7F,
        0x7F,
        0x01,
        0x7F,
        # function: one function of type 0
        0x03,
        0x02,
        0x01,
        0x00,
        # export: "add" = func 0
        0x07,
        0x07,
        0x01,
        0x03,
        "add",
        0x00,
        0x00,
        # code: local.get 0; local.get 1; i32.add; end
        0x0A,
        0x09,
        0x01,
        0x07,
        0x00,
        0x20,
        0x00,
        0x20,
        0x01,
        0x6A,
        0x0B
      >>
  end

  @doc "Exports `run() -> ()` which loops forever."
  @spec infinite_loop() :: binary()
  def infinite_loop do
    @header <>
      <<
        0x01,
        0x04,
        0x01,
        0x60,
        0x00,
        0x00,
        0x03,
        0x02,
        0x01,
        0x00,
        0x07,
        0x07,
        0x01,
        0x03,
        "run",
        0x00,
        0x00,
        # code: loop; br 0; end; end
        0x0A,
        0x09,
        0x01,
        0x07,
        0x00,
        0x03,
        0x40,
        0x0C,
        0x00,
        0x0B,
        0x0B
      >>
  end

  @doc "Exports `run() -> ()` which executes `unreachable`."
  @spec trap_unreachable() :: binary()
  def trap_unreachable do
    @header <>
      <<
        0x01,
        0x04,
        0x01,
        0x60,
        0x00,
        0x00,
        0x03,
        0x02,
        0x01,
        0x00,
        0x07,
        0x07,
        0x01,
        0x03,
        "run",
        0x00,
        0x00,
        # code: unreachable; end
        0x0A,
        0x05,
        0x01,
        0x03,
        0x00,
        0x00,
        0x0B
      >>
  end

  @doc "Exports `run() -> i32` which computes `1 / 0` (integer divide by zero trap)."
  @spec divide_by_zero() :: binary()
  def divide_by_zero do
    @header <>
      <<
        0x01,
        0x05,
        0x01,
        0x60,
        0x00,
        0x01,
        0x7F,
        0x03,
        0x02,
        0x01,
        0x00,
        0x07,
        0x07,
        0x01,
        0x03,
        "run",
        0x00,
        0x00,
        # code: i32.const 1; i32.const 0; i32.div_s; end
        0x0A,
        0x09,
        0x01,
        0x07,
        0x00,
        0x41,
        0x01,
        0x41,
        0x00,
        0x6D,
        0x0B
      >>
  end

  @doc """
  Imports `env.f: () -> ()` and exports `run() -> ()` which calls it.
  Instantiating without the import fails with an unsatisfied import.
  """
  @spec module_with_import() :: binary()
  def module_with_import do
    @header <>
      <<
        0x01,
        0x04,
        0x01,
        0x60,
        0x00,
        0x00,
        # import: "env" "f" func type 0
        0x02,
        0x09,
        0x01,
        0x03,
        "env",
        0x01,
        "f",
        0x00,
        0x00,
        0x03,
        0x02,
        0x01,
        0x00,
        # export: "run" = func 1 (func 0 is the import)
        0x07,
        0x07,
        0x01,
        0x03,
        "run",
        0x00,
        0x01,
        # code: call 0; end
        0x0A,
        0x06,
        0x01,
        0x04,
        0x00,
        0x10,
        0x00,
        0x0B
      >>
  end

  @doc "Exports `run() -> ()` which returns no values and does nothing."
  @spec no_results() :: binary()
  def no_results do
    @header <>
      <<
        0x01,
        0x04,
        0x01,
        0x60,
        0x00,
        0x00,
        0x03,
        0x02,
        0x01,
        0x00,
        0x07,
        0x07,
        0x01,
        0x03,
        "run",
        0x00,
        0x00,
        # code: end
        0x0A,
        0x04,
        0x01,
        0x02,
        0x00,
        0x0B
      >>
  end
end
