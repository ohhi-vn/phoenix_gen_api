#!/usr/bin/env elixir
# Performance comparison: Original vs Optimized

defmodule PerformanceCompare do
  require Logger

  def run do
    IO.puts("\\n" <> String.duplicate("=", 60))
    IO.puts("Performance Comparison: Original vs Optimized")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")

    # Setup test module
    defmodule TestModule do
      def fast_echo(args) do
        {:ok, args}
      end

      def slow_echo(args) do
        Process.sleep(10)
        {:ok, args}
      end
    end

    # Add configs
    configs = [
      %PhoenixGenApi.Structs.FunConfig{
        service: "bench_service",
        request_type: "fast",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {TestModule, :fast_echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      },
      %PhoenixGenApi.Structs.FunConfig{
        service: "bench_service",
        request_type: "slow",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {TestModule, :slow_echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      }
    ]

    Enum.each(configs, fn config ->
      PhoenixGenApi.ConfigDb.add(config)
    end)

    concurrency = 50
    requests_per_worker = 20
    total_requests = concurrency * requests_per_worker

    IO.puts("Running benchmarks with:")
    IO.puts("  Concurrency: #{concurrency}")
    IO.puts("  Requests/worker: #{requests_per_worker}")
    IO.puts("  Total requests: #{total_requests}")
    IO.puts("")

    # Benchmark 1: Fast sync calls (tests Task.async optimization)
    IO.puts("📊 Benchmark 1: Fast sync calls (local)")
    IO.puts(String.duplicate("-", 40))
    {time1, _} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "bench_service",
              request_type: "fast",
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end
      Enum.map(tasks, &Task.await/1)
    end)
    throughput1 = total_requests / (time1 / 1_000_000)
    IO.puts("  Time: #{Float.round(time1 / 1000, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput1, 2)} req/sec")
    IO.puts("")

    # Benchmark 2: Slow sync calls (tests ETS lookup optimization)
    IO.puts("📊 Benchmark 2: Slow sync calls (local, 10ms delay)")
    IO.puts(String.duplicate("-", 40))
    {time2, _} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "bench_service",
              request_type: "slow",
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end
      Enum.map(tasks, &Task.await/1)
    end)
    throughput2 = total_requests / (time2 / 1_000_000)
    IO.puts("  Time: #{Float.round(time2 / 1000, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput2, 2)} req/sec")
    IO.puts("")

    IO.puts(String.duplicate("=", 60))
    IO.puts("Benchmark complete!")
    IO.puts(String.duplicate("=", 60))
  end
end

PerformanceCompare.run()
