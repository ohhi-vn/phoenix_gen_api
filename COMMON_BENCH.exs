#!/usr/bin/env elixir
alias PhoenixGenApi.{Executor, ConfigDb, Structs.Request, Structs.FunConfig}

defmodule BenchMod do
  def fast(args), do: {:ok, args}
  def slow(args) do
    Process.sleep(10)
    {:ok, args}
  end
end

configs = [
  %FunConfig{
    service: "bench",
    request_type: "fast",
    nodes: :local,
    choose_node_mode: :random,
    mfa: {BenchMod, :fast, []},
    response_type: :sync,
    timeout: 5000,
    arg_types: %{},
    arg_orders: []
  },
  %FunConfig{
    service: "bench",
    request_type: "slow",
    nodes: :local,
    choose_node_mode: :random,
    mfa: {BenchMod, :slow, []},
    response_type: :sync,
    timeout: 5000,
    arg_types: %{},
    arg_orders: []
  }
]

Enum.each(configs, fn c -> ConfigDb.add(c) end)

concurrency = 50
requests_per_worker = 20
total = concurrency * requests_per_worker

IO.puts("Concurrency: #{concurrency}, Requests/worker: #{requests_per_worker}, Total: #{total}")

# Benchmark fast calls
{time1, _} = :timer.tc(fn ->
  tasks = for i <- 1..concurrency do
    Task.async(fn ->
      for j <- 1..requests_per_worker do
        req = %Request{
          service: "bench",
          request_type: "fast",
          request_id: "req_#{i}_#{j}",
          args: %{}
        }
        Executor.execute!(req)
      end
    end)
  end
  Enum.map(tasks, &Task.await/1)
end)

throughput1 = total / (time1 / 1_000_000)
IO.puts("Fast calls: #{Float.round(time1/1000, 2)}ms, #{Float.round(throughput1, 2)} req/sec")

# Benchmark slow calls
{time2, _} = :timer.tc(fn ->
  tasks = for i <- 1..concurrency do
    Task.async(fn ->
      for j <- 1..requests_per_worker do
        req = %Request{
          service: "bench",
          request_type: "slow",
          request_id: "req_#{i}_#{j}",
          args: %{}
        }
        Executor.execute!(req)
      end
    end)
  end
  Enum.map(tasks, &Task.await/1)
end)

throughput2 = total / (time2 / 1_000_000)
IO.puts("Slow calls: #{Float.round(time2/1000, 2)}ms, #{Float.round(throughput2, 2)} req/sec")
