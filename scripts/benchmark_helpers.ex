defmodule BenchmarkHelpers do
  @moduledoc """
  Helper module for benchmark tests.
  """

  def echo(), do: echo(%{})
  def echo(args) do
    {:ok, args}
  end

  def slow_echo(), do: slow_echo(%{})
  def slow_echo(args) do
    Process.sleep(10)
    {:ok, args}
  end

  def fast_echo(), do: fast_echo(%{})
  def fast_echo(args) do
    {:ok, args}
  end
end
