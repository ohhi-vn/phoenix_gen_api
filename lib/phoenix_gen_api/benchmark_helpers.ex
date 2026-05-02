defmodule PhoenixGenApi.BenchmarkHelpers do
  @moduledoc """
  Helper module for benchmark tests.
  """

  def echo(args) do
    {:ok, args}
  end

  def slow_echo(args) do
    Process.sleep(10)
    {:ok, args}
  end

  def fast_echo(args) do
    {:ok, args}
  end
end
