defmodule PhoenixGenApi.WorkerPool.CircuitBreaker do
  @moduledoc """
  Shared circuit breaker functions for WorkerPool and Worker.

  This module provides common circuit breaker logic to avoid
  code duplication between the pool-level and worker-level
  circuit breakers.
  """

  @doc """
  Checks if the circuit breaker is open (in cooldown period).

  Returns `true` if the circuit breaker is open (rejecting requests),
  `false` if requests should be allowed.

  ## Parameters

  - `circuit_open_at`: The monotonic time (in milliseconds) when the circuit
    was opened, or `nil` if the circuit is closed.
  - `cooldown_ms`: The cooldown period in milliseconds.

  ## Examples

      iex> CircuitBreaker.circuit_open?(nil, 5000)
      false

      iex> now = System.monotonic_time(:millisecond)
      iex> CircuitBreaker.circuit_open?(now, 5000)
      true
  """
  def circuit_open?(nil, _cooldown_ms), do: false

  def circuit_open?(opened_at, cooldown_ms) when is_integer(opened_at) do
    System.monotonic_time(:millisecond) - opened_at < cooldown_ms
  end
end
