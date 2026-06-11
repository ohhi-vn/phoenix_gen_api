defmodule PhoenixGenApi.WorkerPool.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.WorkerPool.CircuitBreaker

  describe "circuit_open?/2" do
    test "returns false when circuit_open_at is nil" do
      assert CircuitBreaker.circuit_open?(nil, 5000) == false
    end

    test "returns false when circuit_open_at is nil regardless of cooldown" do
      assert CircuitBreaker.circuit_open?(nil, 0) == false
      assert CircuitBreaker.circuit_open?(nil, 1_000_000) == false
    end

    test "returns true when circuit was just opened" do
      now = System.monotonic_time(:millisecond)
      assert CircuitBreaker.circuit_open?(now, 5000) == true
    end

    test "returns true when circuit opened within cooldown period" do
      now = System.monotonic_time(:millisecond)
      opened_at = now - 1000
      assert CircuitBreaker.circuit_open?(opened_at, 5000) == true
    end

    test "returns false when circuit opened before cooldown period" do
      now = System.monotonic_time(:millisecond)
      opened_at = now - 10_000
      assert CircuitBreaker.circuit_open?(opened_at, 5000) == false
    end

    test "returns true at the boundary of cooldown period" do
      now = System.monotonic_time(:millisecond)
      # Opened exactly cooldown_ms ago — difference is NOT less than cooldown
      opened_at = now - 5000
      assert CircuitBreaker.circuit_open?(opened_at, 5000) == false
    end

    test "returns true just within the boundary of cooldown period" do
      now = System.monotonic_time(:millisecond)
      # Opened just within cooldown - use a larger margin to avoid timing flakiness
      opened_at = now - 4900
      assert CircuitBreaker.circuit_open?(opened_at, 5000) == true
    end

    test "works with zero cooldown" do
      now = System.monotonic_time(:millisecond)
      # With 0 cooldown, only exactly "now" would be open
      assert CircuitBreaker.circuit_open?(now, 0) == false
    end

    test "works with very large cooldown" do
      now = System.monotonic_time(:millisecond)
      opened_at = now - 1
      assert CircuitBreaker.circuit_open?(opened_at, 3_600_000) == true
    end
  end
end
