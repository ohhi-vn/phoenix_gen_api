#!/usr/bin/env elixir
# Performance comparison: Original vs Optimized

defmodule PerfCompare do
  def run do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Performance Comparison: Original (8296995) vs Optimized (HEAD)")
    IO.puts(String.duplicate("=", 70))
    IO.puts("")

    # Setup
    setup_test_module()
    setup_configs()

    concurrency = 50
    requests_per_worker = 20
    total = concurrency * requests_per_worker
    iterations = 3

    IO.puts("Test parameters:")
    IO.puts("  Concurrency: #{concurrency}")
    IO.puts("  Requests/worker: #{requests_per_worker}")
    IO.puts("  Total requests: #{total}")
    IO.puts("  Iterations: #{iterations}")
    IO.puts("")

    # Benchmark: Fast sync calls (tests Task.async optimization)
    IO.puts("📊 Benchmark 1: Fast sync calls (local, no delay)")
    IO.puts(String.duplicate("-", 50))
    
    times1 = for _ <- 1..iterations do
      {time, _} = :timer.tc(fn ->
        tasks = for i <- 1..concurrency do
          Task.async(fn ->
            for j <- 1..requests_per_worker do
              req = %PhoenixGenApi.Structs.Request{
                service: "bench_service",
                request_type: "fast",
                request_id: "req_#{i}_#{j}",
                args: %{}
              }
              PhoenixGenApi.Executor.execute!(req)
            end
          end)
        end
        Enum.map(tasks, &Task.await/1)
      end)
      time / 1000  # Convert to ms
    end

    avg1 = Enum.sum(times1) / length(times1)
    throughput1 = total / (avg1 / 1000)
    IO.puts("  Average time: #{Float.round(avg1, 2)}ms")
    IO.puts("  Average throughput: #{Float.round(throughput1, 2)} req/sec")
    IO.puts("")

    # Benchmark: Slow sync calls (tests ETS lookup optimization)
    IO.puts("📊 Benchmark 2: Slow sync calls (local, 10ms delay)")
    IO.puts(String.duplicate("-", 50))
    
    times2 = for _ <- 1..iterations do
      {time, _} = :timer.tc(fn ->
        tasks = for i <- 1..concurrency do
          Task.async(fn ->
            for j <- 1..requests_per_worker do
              req = %PhoenixGenApi.Structs.Request{
                service: "bench_service",
                request_type: "slow",
                request_id: "req_#{i}_#{j}",
                args: %{}
              }
              PhoenixGenApi.Executor.execute!(req)
            end
          end)
        end
        Enum.map(tasks, &Task.await/1)
      end)
      time / 1000
    end

    avg2 = Enum.sum(times2) / length(times2)
    throughput2 = total / (avg2 / 1000)
    IO.puts("  Average time: #{Float.round(avg2, 2)}ms")
    IO.puts("  Average throughput: #{Float.round(throughput2, 2)} req/sec")
    IO.puts("")

    IO.puts(String.duplicate("=", 70))
    IO.puts("Benchmark complete!")
    IO.puts(String.duplicate("=", 70))
  end

  defp setup_test_module do
    defmodule TestMod do
      def fast_echo(args), do: {:ok, args}
      def slow_echo(args) do
        Process.sleep(10)
        {:ok, args}
      end
    end
  end

  defp setup_configs do
    configs = [
      %PhoenixGenApi.Structs.FunConfig{
        service: "bench_service",
        request_type: "fast",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {TestMod, :fast_echo, []},
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
        mfa: {TestMod, :slow_echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      }
    ]
    Enum.each(configs, fn c -> PhoenixGenApi.ConfigDb.add(c) end)
  end
end

PerfCompare.run()
