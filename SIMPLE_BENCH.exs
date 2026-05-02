#!/usr/bin/env elixir
alias PhoenixGenApi.{Executor, ConfigDb, Structs.Request, Structs.FunConfig}

# Setup
defmodule SMod do
  def fast(args), do: {:ok, args}
end

ConfigDb.add(%FunConfig{
  service: "bench", request_type: "fast",
  nodes: :local, choose_node_mode: :random,
  mfa: {SMod, :fast, []}, response_type: :sync,
  timeout: 5000, arg_types: %{}, arg_orders: []
})

# Benchmark
{time, _} = :timer.tc(fn ->
  for _ <- 1..1000 do
    req = %Request{service: "bench", request_type: "fast", request_id: "test"}
    Executor.execute!(req)
  end
end)

ms = time / 1000
throughput = 1000 / (time / 1_000_000)
IO.puts("Time: #{Float.round(ms, 2)}ms")
IO.puts("Throughput: #{Float.round(throughput, 2)} req/sec")
