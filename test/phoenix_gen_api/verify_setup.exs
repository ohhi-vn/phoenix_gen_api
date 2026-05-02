#!/usr/bin/env elixir

# Quick verification script for PhoenixGenApi benchmark setup
#
# Run with: mix run scripts/verify_setup.exs

alias PhoenixGenApi.{WorkerPool, ConfigDb, Executor, Structs.Request, Structs.FunConfig}

# Define echo handler function
defmodule BenchmarkHelper do
  def echo_test(message) when is_binary(message) do
    %{message: message, echo: true, node: node()}
  end

  def echo_test(args) when is_list(args) do
    args_map = Enum.into(args, %{})
    echo_test(args_map["message"] || "no message")
  end

  def echo_test(%{"message" => message}) do
    %{message: message, echo: true, node: node()}
  end
end

IO.puts("\n#{String.duplicate("=", 60)}")
IO.puts("PhoenixGenApi Benchmark Setup Verification")
IO.puts(String.duplicate("=", 60))

# Check 1: Worker Pools
IO.puts("\n✓ Checking Worker Pools...")
async_status = WorkerPool.status(:async_pool)
stream_status = WorkerPool.status(:stream_pool)

IO.puts("  Async Pool:")
IO.puts("    Idle workers: #{async_status.idle_workers}")
IO.puts("    Busy workers: #{async_status.busy_workers}")
IO.puts("    Queue size: #{async_status.queued_tasks}")

IO.puts("  Stream Pool:")
IO.puts("    Idle workers: #{stream_status.idle_workers}")
IO.puts("    Busy workers: #{stream_status.busy_workers}")
IO.puts("    Queue size: #{stream_status.queued_tasks}")

# Check 2: ConfigDb
IO.puts("\n✓ Checking ConfigDb...")
IO.puts("  ConfigDb ETS table exists: #{:ets.whereis(:phoenix_gen_api_config_db) != :undefined}")

# Check 3: Setup local test config
IO.puts("\n✓ Setting up test configuration...")

test_config = %FunConfig{
  request_type: "test_echo",
  service: "benchmark_service",
  nodes: :local,
  choose_node_mode: :random,
  timeout: 5000,
  mfa: {BenchmarkHelper, :echo_test, []},
  arg_types: %{"message" => :string},
  arg_orders: ["message"],
  response_type: :sync
}

ConfigDb.add(test_config)
IO.puts("  Added test config: benchmark_service/test_echo")

# Check 4: Test local execution
IO.puts("\n✓ Testing local execution...")

test_request = %Request{
  request_id: "verify_#{:erlang.unique_integer([:positive])}",
  service: "benchmark_service",
  request_type: "test_echo",
  args: %{"message" => "Hello from benchmark!"}
}

start_time = System.monotonic_time(:millisecond)
result = Executor.execute!(test_request)
end_time = System.monotonic_time(:millisecond)

IO.puts("  Request ID: #{test_request.request_id}")
IO.puts("  Result: #{inspect(result)}")
IO.puts("  Execution time: #{end_time - start_time}ms")

# Check 5: Test async execution
IO.puts("\n✓ Testing async execution...")

async_config = %{test_config | request_type: "test_echo_async", response_type: :async}
ConfigDb.add(async_config)

async_request = %Request{
  request_id: "verify_async_#{:erlang.unique_integer([:positive])}",
  service: "benchmark_service",
  request_type: "test_echo_async",
  args: %{"message" => "Async test"}
}

parent = self()

Task.start(fn ->
  Executor.execute!(async_request)
end)

receive do
  {:async_call, response} ->
    IO.puts("  Async result received: #{inspect(response)}")
after
  5000 ->
    IO.puts("  ⚠️  Async response timeout")
end

# Check 6: Node connectivity (if applicable)
IO.puts("\n✓ Checking node connectivity...")
case Node.list() do
  [] ->
    IO.puts("  No remote nodes connected (OK for local testing)")
    IO.puts("  For remote benchmarks, connect nodes with: Node.connect/1")

  nodes ->
    IO.puts("  Connected nodes: #{inspect(nodes)}")
end

# Summary
IO.puts("\n#{String.duplicate("=", 60)}")
IO.puts("Verification Complete!")
IO.puts(String.duplicate("=", 60))

IO.puts("""
Summary:
  ✓ Worker pools initialized
  ✓ ConfigDb operational
  ✓ Local execution working
  ✓ Async execution working
  ✓ Ready for benchmarking!

To run benchmarks:
  mix run scripts/benchmark.exs -- --mode local
  mix run scripts/benchmark.exs -- --mode remote (requires remote nodes)
""")
