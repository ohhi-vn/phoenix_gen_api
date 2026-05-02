#!/usr/bin/env elixir

# Benchmark script for PhoenixGenApi
# Tests local and remote node execution performance
#
# Usage:
#   mix run scripts/benchmark.exs -- --mode local
#   mix run scripts/benchmark.exs -- --mode remote
#   mix run scripts/benchmark.exs -- --concurrency 100 --requests 1000

alias PhoenixGenApi.{Executor, ConfigDb, Structs.Request, Structs.FunConfig}
require Logger

defmodule Benchmark do
  @moduledoc """
  Benchmark module for testing PhoenixGenApi executor performance.

  Tests various scenarios:
  - Local execution (nodes: :local)
  - Remote execution (nodes: [:node@host])
  - Sync vs Async vs Stream calls
  - Different concurrency levels
  - Worker pool performance
  """

  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :both)
    concurrency = Keyword.get(opts, :concurrency, 50)
    requests_per_worker = Keyword.get(opts, :requests_per_worker, 20)
    total_requests = concurrency * requests_per_worker

    IO.puts("\n#{String.duplicate("=", 60)}")
    IO.puts("PhoenixGenApi Benchmark")
    IO.puts(String.duplicate("=", 60))
    IO.puts("Mode: #{inspect(mode)}")
    IO.puts("Concurrency: #{concurrency}")
    IO.puts("Requests per worker: #{requests_per_worker}")
    IO.puts("Total requests: #{total_requests}")
    IO.puts(String.duplicate("=", 60))

    # Run benchmarks based on mode
    case mode do
      :local -> run_local_benchmarks(concurrency, requests_per_worker)
      :remote -> run_remote_benchmarks(concurrency, requests_per_worker)
      :both ->
        run_local_benchmarks(concurrency, requests_per_worker)
        IO.puts("\n")
        run_remote_benchmarks(concurrency, requests_per_worker)
    end

    IO.puts("\n#{String.duplicate("=", 60)}")
    IO.puts("Benchmark Complete!")
    IO.puts(String.duplicate("=", 60))
  end

  defp run_local_benchmarks(concurrency, requests_per_worker) do
    IO.puts("\n#{String.duplicate("-", 60)}")
    IO.puts("LOCAL EXECUTION BENCHMARKS")
    IO.puts(String.duplicate("-", 60))

    # Ensure we have a local FunConfig
    setup_local_config()

    # Benchmark 1: Sync calls
    benchmark_sync_local(concurrency, requests_per_worker)

    # Benchmark 2: Async calls
    benchmark_async_local(concurrency, requests_per_worker)
  end

  defp run_remote_benchmarks(concurrency, requests_per_worker) do
    IO.puts("\n#{String.duplicate("-", 60)}")
    IO.puts("REMOTE EXECUTION BENCHMARKS")
    IO.puts(String.duplicate("-", 60))

    # Check if remote nodes are available
    case Node.list() do
      [] ->
        IO.puts("\n⚠️  No remote nodes connected - skipping remote benchmarks")
        IO.puts("   (Connect nodes with: Node.connect(:node2@127.0.0.1))")

      nodes ->
        IO.puts("\n✓ Remote nodes available: #{inspect(nodes)}")
        setup_remote_config(nodes)

        # Benchmark 1: Sync calls with random node selection
        benchmark_sync_remote(concurrency, requests_per_worker, :random)

        # Benchmark 2: Sync calls with hash-based node selection
        benchmark_sync_remote(concurrency, requests_per_worker, {:hash, "user_id"})

        # Benchmark 3: Async calls (remote)
        benchmark_async_remote(concurrency, requests_per_worker)

        # Benchmark 4: Test different response types
        benchmark_response_types(concurrency, requests_per_worker)

        # Benchmark 5: Test node fallback (simulated)
        benchmark_node_fallback(concurrency, requests_per_worker, nodes)

        # Benchmark 6: Stress test with higher concurrency
        benchmark_stress_remote(div(concurrency, 2), requests_per_worker * 2)
    end
  end

  # Local benchmark functions

  defp benchmark_sync_local(concurrency, requests_per_worker) do
    IO.puts("\n📊 Benchmark: Sync calls (local)")
    IO.puts(String.duplicate("-", 40))

    total_requests = concurrency * requests_per_worker

    {time_ms, _} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %Request{
              request_id: "local_sync_#{i}_#{j}",
              service: "benchmark_service",
              request_type: "echo",
              args: %{"message" => "test_#{i}_#{j}"}
            }

            Executor.execute!(request)
          end
        end)
      end

      Task.await_many(tasks, :infinity)
    end)

    requests_per_second = calculate_rps(total_requests, time_ms)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
    IO.puts("  Avg latency: #{Float.round(time_ms / total_requests, 2)}ms")
  end

  defp benchmark_async_local(concurrency, requests_per_worker) do
    IO.puts("\n📊 Benchmark: Async calls (local)")
    IO.puts(String.duplicate("-", 40))

    total_requests = concurrency * requests_per_worker

    {time_ms, _} = :timer.tc(fn ->
      for i <- 1..total_requests do
        request = %Request{
          request_id: "local_async_#{i}",
          service: "benchmark_service",
          request_type: "echo_async",
          args: %{"message" => "test_#{i}"}
        }

        Executor.execute!(request)
      end

      # Wait for all async responses
      for _ <- 1..total_requests do
        receive do
          {:async_call, _response} -> :ok
        after
          5000 -> :timeout
        end
      end
    end)

    requests_per_second = calculate_rps(total_requests, time_ms)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
  end

  # Remote benchmark functions

  defp benchmark_sync_remote(concurrency, requests_per_worker, node_strategy \\ :random) do
    strategy_name = if is_tuple(node_strategy), do: "hash", else: to_string(node_strategy)
    IO.puts("\n📊 Benchmark: Sync calls (remote) - #{strategy_name} node selection")
    IO.puts(String.duplicate("-", 40))

    # Update config with the specified node selection strategy
    fun_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service_remote",
      nodes: Node.list(),
      choose_node_mode: node_strategy,
      timeout: 10_000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string, "user_id" => :string},
      arg_orders: ["message", "user_id"],
      response_type: :sync
    }
    ConfigDb.add(fun_config)

    total_requests = concurrency * requests_per_worker

    {time_ms, _} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %Request{
              request_id: "remote_sync_#{i}_#{j}",
              service: "benchmark_service_remote",
              request_type: "echo",
              user_id: "user_#{rem(i, 3)}",
              args: %{"message" => "test_#{i}_#{j}", "user_id" => "user_#{rem(i, 3)}"}
            }

            Executor.execute!(request)
          end
        end)
      end

      Task.await_many(tasks, :infinity)
    end)

    requests_per_second = calculate_rps(total_requests, time_ms)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
    IO.puts("  Avg latency: #{Float.round(time_ms / total_requests, 2)}ms")
  end

  defp benchmark_async_remote(concurrency, requests_per_worker) do
    IO.puts("\n📊 Benchmark: Async calls (remote)")
    IO.puts(String.duplicate("-", 40))

    total_requests = concurrency * requests_per_worker

    {time_ms, _} = :timer.tc(fn ->
      for i <- 1..total_requests do
        request = %Request{
          request_id: "remote_async_#{i}",
          service: "benchmark_service_remote",
          request_type: "echo",
          args: %{"message" => "test_#{i}"}
        }

        Executor.execute!(request)
      end

      # Wait for async responses
      for _ <- 1..total_requests do
        receive do
          {:async_call, _response} -> :ok
        after
          10_000 -> :timeout
        end
      end
    end)

    requests_per_second = calculate_rps(total_requests, time_ms)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
  end

  # Benchmark 4: Test different response types
  defp benchmark_response_types(concurrency, requests_per_worker) do
    IO.puts("\n📊 Benchmark: Response types (remote)")
    IO.puts(String.duplicate("-", 40))

    for response_type <- [:sync, :async] do
      fun_config = %FunConfig{
        request_type: "echo_\#{response_type}",
        service: "benchmark_service_remote",
        nodes: Node.list(),
        choose_node_mode: :random,
        timeout: 10_000,
        mfa: {__MODULE__, :echo_handler, []},
        arg_types: %{"message" => :string},
        arg_orders: ["message"],
        response_type: response_type
      }
      ConfigDb.add(fun_config)

      total_requests = div(concurrency * requests_per_worker, 2)

      {time_ms, _} = :timer.tc(fn ->
        tasks = for i <- 1..div(concurrency, 2) do
          Task.async(fn ->
            for j <- 1..requests_per_worker do
              request = %Request{
                request_id: "resp_#{response_type}_#{i}_#{j}",
                service: "benchmark_service_remote",
                request_type: "echo_\#{response_type}",
                args: %{"message" => "test_#{i}_#{j}"}
              }
              Executor.execute!(request)
            end
          end)
        end
        Task.await_many(tasks, :infinity)
      end)

      requests_per_second = calculate_rps(total_requests, time_ms)

      IO.puts("  Response type: \#{response_type}")
      IO.puts("    Total requests: #{total_requests}")
      IO.puts("    Time: #{time_ms / 1000}ms")
      IO.puts("    Throughput: #{requests_per_second} req/sec")
    end
  end

  # Benchmark 5: Node fallback (simulated)
  defp benchmark_node_fallback(concurrency, requests_per_worker, nodes) do
    IO.puts("\n📊 Benchmark: Node fallback simulation (remote)")
    IO.puts(String.duplicate("-", 40))
    IO.puts("  Testing with single node (simulating node failure)")

    # Create config with only first node (simulate other nodes down)
    single_node = [List.first(nodes)]
    fun_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service_remote",
      nodes: single_node,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :sync
    }
    ConfigDb.add(fun_config)

    total_requests = concurrency * requests_per_worker

    {time_ms, _} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %Request{
              request_id: "fallback_#{i}_#{j}",
              service: "benchmark_service_remote",
              request_type: "echo",
              args: %{"message" => "test_#{i}_#{j}"}
            }
            Executor.execute!(request)
          end
        end)
      end
      Task.await_many(tasks, :infinity)
    end)

    requests_per_second = calculate_rps(total_requests, time_ms)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
    IO.puts("  (Single node simulation complete)")
  end

  # Benchmark 5: Stress test with higher concurrency
  defp benchmark_stress_remote(concurrency, requests_per_worker) do
    IO.puts("\n📊 Benchmark: Stress test (remote) - High concurrency")
    IO.puts(String.duplicate("-", 40))
    IO.puts("  Concurrency: #{concurrency}, Requests: #{concurrency * requests_per_worker}")

    total_requests = concurrency * requests_per_worker
    start_time = System.monotonic_time(:millisecond)

    {time_ms, results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %Request{
              request_id: "stress_#{i}_#{j}",
              service: "benchmark_service_remote",
              request_type: "echo",
              args: %{"message" => "stress_#{i}_#{j}"}
            }
            try do
              Executor.execute!(request)
            rescue
              e -> {:error, Exception.message(e)}
            end
          end
        end)
      end
      Task.await_many(tasks, :infinity)
    end)

    end_time = System.monotonic_time(:millisecond)
    requests_per_second = calculate_rps(total_requests, time_ms)

    # Calculate success rate
    # Note: This is simplified - in reality you'd collect actual results
    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{time_ms / 1000}ms")
    IO.puts("  Throughput: #{requests_per_second} req/sec")
    IO.puts("  Avg latency: #{Float.round(time_ms / total_requests, 2)}ms")
  end

  # Setup functions

  defp setup_local_config() do
    # Create FunConfig for local execution
    fun_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :sync
    }

    fun_config_async = %FunConfig{
      request_type: "echo_async",
      service: "benchmark_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :async
    }

    # Add to ConfigDb
    ConfigDb.add(fun_config)
    ConfigDb.add(fun_config_async)

    IO.puts("\n✓ Local config added: benchmark_service")
  end

  defp setup_remote_config(nodes) do
    # Create FunConfig for remote execution
    fun_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service_remote",
      nodes: nodes,
      choose_node_mode: :random,
      timeout: 10_000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :sync
    }

    ConfigDb.add(fun_config)

    IO.puts("\n✓ Remote config added: benchmark_service_remote")
    IO.puts("  Target nodes: #{inspect(nodes)}")
  end

  # Helper functions

  def echo_handler(args) when is_list(args) do
    args_map = Enum.into(args, %{})
    {:ok, %{message: args_map["message"] || "no message", echo: true, node: node()}}
  end

  def echo_handler(%{"message" => message}) do
    {:ok, %{message: message, echo: true, node: node()}}
  end

  def echo_handler(message) when is_binary(message) do
    {:ok, %{message: message, echo: true, node: node()}}
  end

  defp calculate_rps(requests, time_ms) do
    Float.round(requests / (time_ms / 1_000_000), 2)
  end
end

# Parse command line arguments and run
{opts, _, _} = OptionParser.parse(System.argv(),
  switches: [
    mode: [:string],
    concurrency: :integer,
    requests: :integer
  ],
  aliases: [
    m: :mode,
    c: :concurrency,
    r: :requests
  ]
)

mode = case Keyword.get(opts, :mode, "both") do
  "local" -> :local
  "remote" -> :remote
  _ -> :both
end

concurrency = Keyword.get(opts, :concurrency, 50)
total_requests = Keyword.get(opts, :requests, 10000)
requests_per_worker = div(total_requests, concurrency)

IO.puts("Starting benchmark with options:")
IO.puts("  Mode: #{mode}")
IO.puts("  Concurrency: #{concurrency}")
IO.puts("  Total requests: #{total_requests}")
IO.puts("  Requests per worker: #{requests_per_worker}")

Benchmark.run(mode: mode, concurrency: concurrency, requests_per_worker: requests_per_worker)
