#!/usr/bin/env elixir
# Benchmark script for PhoenixGenApi
# Usage: mix run scripts/benchmark.exs -- --mode local --concurrency 50 --requests 1000

defmodule PhoenixGenApi.Benchmark do
  require Logger

  @default_concurrency 50
  @default_requests 1000

  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      aliases: [m: :mode, c: :concurrency, r: :requests],
      strict: [mode: :string, concurrency: :integer, requests: :integer]
    )

    mode = Keyword.get(opts, :mode, "both") |> String.to_atom()
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    requests = Keyword.get(opts, :requests, @default_requests)
    requests_per_worker = div(requests, concurrency)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("PhoenixGenApi Benchmark")
    IO.puts(String.duplicate("=", 60))
    IO.puts("Mode: #{mode}")
    IO.puts("Concurrency: #{concurrency}")
    IO.puts("Requests per worker: #{requests_per_worker}")
    IO.puts("Total requests: #{requests}")
    IO.puts(String.duplicate("=", 60) <> "\n")

    # Setup test configuration
    setup_test_config()

    # Print worker pool status
    IO.puts("Worker Pool Status:")
    IO.puts(PhoenixGenApi.pool_status() |> inspect(pretty: true))
    IO.puts("")

    case mode do
      :local ->
        run_local_benchmarks(concurrency, requests_per_worker)

      :remote ->
        run_remote_benchmarks(concurrency, requests_per_worker)

      :both ->
        run_local_benchmarks(concurrency, requests_per_worker)
        IO.puts("")
        run_remote_benchmarks(concurrency, requests_per_worker)
    end

    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("Benchmark complete!")
    IO.puts(String.duplicate("-", 60))
  end

  defp setup_test_config() do
    # Define a simple echo function for testing
    defmodule BenchmarkHelpers do
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

    # Push local configs with required fields
    configs = [
      %PhoenixGenApi.Structs.FunConfig{
        service: "benchmark_service",
        request_type: "echo",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {BenchmarkHelpers, :echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      },
      %PhoenixGenApi.Structs.FunConfig{
        service: "benchmark_service",
        request_type: "fast_echo",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {BenchmarkHelpers, :fast_echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      },
      %PhoenixGenApi.Structs.FunConfig{
        service: "benchmark_service",
        request_type: "slow_echo",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {BenchmarkHelpers, :slow_echo, []},
        response_type: :sync,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      },
      %PhoenixGenApi.Structs.FunConfig{
        service: "benchmark_service",
        request_type: "async_echo",
        nodes: :local,
        choose_node_mode: :random,
        mfa: {BenchmarkHelpers, :echo, []},
        response_type: :async,
        timeout: 5000,
        arg_types: %{},
        arg_orders: []
      }
    ]

    Enum.each(configs, fn config ->
      case PhoenixGenApi.ConfigDb.add(config) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to add config: #{inspect(reason)}")
      end
    end)

    Logger.info("Benchmark test configs added")
  end

  defp run_local_benchmarks(concurrency, requests_per_worker) do
    IO.puts(String.duplicate("-", 60))
    IO.puts("LOCAL EXECUTION BENCHMARKS")
    IO.puts(String.duplicate("-", 60) <> "\n")

    # Benchmark 1: Fast sync calls
    benchmark_sync_calls("fast_echo", "Fast sync calls (local, no args)", concurrency, requests_per_worker)

    # Benchmark 2: Normal sync calls
    benchmark_sync_calls("echo", "Sync calls (local, no args)", concurrency, requests_per_worker)

    # Benchmark 3: Slow sync calls
    benchmark_sync_calls("slow_echo", "Slow sync calls (local, 10ms delay)", concurrency, requests_per_worker)

    # Benchmark 4: Async calls
    benchmark_async_calls("async_echo", "Async calls (local)", concurrency, requests_per_worker)
  end

  defp run_remote_benchmarks(concurrency, requests_per_worker) do
    IO.puts(String.duplicate("-", 60))
    IO.puts("REMOTE EXECUTION BENCHMARKS")
    IO.puts(String.duplicate("-", 60) <> "\n")

    connected_nodes = Node.list()

    if connected_nodes == [] do
      IO.puts("⚠️  No remote nodes connected! Skipping remote benchmarks.")
      IO.puts("   Start worker nodes and connect them to run remote benchmarks.")
      IO.puts("   See scripts/README.md for instructions.")
    else
      IO.puts("Connected nodes: #{inspect(connected_nodes)}")
      IO.puts("")

      benchmark_remote_sync_calls(concurrency, requests_per_worker)
      benchmark_remote_async_calls(concurrency, requests_per_worker)
    end
  end

  defp benchmark_sync_calls(request_type, description, concurrency, requests_per_worker) do
    IO.puts("📊 Benchmark: #{description}")
    IO.puts(String.duplicate("-", 40))

    {time_us, results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "benchmark_service",
              request_type: request_type,
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end

      Enum.map(tasks, &Task.await/1)
    end)

    total_requests = concurrency * requests_per_worker
    time_ms = time_us / 1000
    throughput = total_requests / (time_us / 1_000_000)
    avg_latency_ms = time_ms / total_requests

    # Count successes
    successes = Enum.flat_map(results, fn r -> r end)
      |> Enum.count(fn
        %PhoenixGenApi.Structs.Response{success: true} -> true
        _ -> false
      end)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Successful: #{successes}")
    IO.puts("  Time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput, 2)} req/sec")
    IO.puts("  Avg latency: #{Float.round(avg_latency_ms * 1000, 2)}μs")
    IO.puts("")
  end

  defp benchmark_async_calls(request_type, description, concurrency, requests_per_worker) do
    IO.puts("📊 Benchmark: #{description}")
    IO.puts(String.duplicate("-", 40))

    {time_us, _results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "benchmark_service",
              request_type: request_type,
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end

      Enum.map(tasks, &Task.await/1)
    end)

    total_requests = concurrency * requests_per_worker
    time_ms = time_us / 1000
    throughput = total_requests / (time_us / 1_000_000)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput, 2)} req/sec")
    IO.puts("")
  end

  defp benchmark_remote_sync_calls(concurrency, requests_per_worker) do
    IO.puts("📊 Benchmark: Sync calls (remote)")
    IO.puts(String.duplicate("-", 40))

    {time_us, _results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "benchmark_service",
              request_type: "echo",
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end

      Enum.map(tasks, &Task.await/1)
    end)

    total_requests = concurrency * requests_per_worker
    time_ms = time_us / 1000
    throughput = total_requests / (time_us / 1_000_000)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput, 2)} req/sec")
    IO.puts("")
  end

  defp benchmark_remote_async_calls(concurrency, requests_per_worker) do
    IO.puts("📊 Benchmark: Async calls (remote)")
    IO.puts(String.duplicate("-", 40))

    {time_us, _results} = :timer.tc(fn ->
      tasks = for i <- 1..concurrency do
        Task.async(fn ->
          for j <- 1..requests_per_worker do
            request = %PhoenixGenApi.Structs.Request{
              service: "benchmark_service",
              request_type: "async_echo",
              request_id: "req_#{i}_#{j}",
              args: %{}
            }
            PhoenixGenApi.Executor.execute!(request)
          end
        end)
      end

      Enum.map(tasks, &Task.await/1)
    end)

    total_requests = concurrency * requests_per_worker
    time_ms = time_us / 1000
    throughput = total_requests / (time_us / 1_000_000)

    IO.puts("  Total requests: #{total_requests}")
    IO.puts("  Time: #{Float.round(time_ms, 2)}ms")
    IO.puts("  Throughput: #{Float.round(throughput, 2)} req/sec")
    IO.puts("")
  end
end

# Parse arguments and run
PhoenixGenApi.Benchmark.run(System.argv())
