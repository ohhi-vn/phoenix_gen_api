# Quick Start Guide - PhoenixGenApi Benchmarks

## Prerequisites

- PhoenixGenApi project compiled: `mix compile`
- Elixir installed

## 1. Quick Local Benchmark (No remote nodes needed)

```bash
cd /path/to/phoenix_gen_api
mix run scripts/verify_setup.exs
```

This will:

- Verify worker pools are running (1000 async, 500 stream, 10000 queue)
- Test local execution
- Confirm everything is working

Then run the actual benchmark:

```bash
mix run scripts/benchmark.exs -- --mode local --concurrency 50 --requests 1000
```

## 2. Understanding the Output

```text
============================================================
PhoenixGenApi Benchmark
============================================================
Mode: :local
Concurrency: 50
Requests per worker: 20
Total requests: 1000
============================================================

Worker Pool Status:
  Async pool: %{idle_workers: 1000, busy_workers: 0, ...}
  Stream pool: %{idle_workers: 500, busy_workers: 0, ...}

------------------------------------------------------------
LOCAL EXECUTION BENCHMARKS
------------------------------------------------------------

📊 Benchmark: Sync calls (local)
----------------------------------------
  Total requests: 1000
  Time: 1234.5ms
  Throughput: 810.23 req/sec
  Avg latency: 1.23ms
```

**Key Metrics:**

- **Throughput (req/sec)**: Higher is better
- **Avg latency (ms)**: Lower is better
- **Time (ms)**: Total execution time

## 3. Multi-Node Benchmark (Optional)

### Terminal 1 - Main Node:

```bash
iex --name main@127.0.0.1 -S mix
```

### Terminal 2 - Worker Node:

```bash
iex --name node2@127.0.0.1 -S mix
```

Then in the worker node shell:

```elixir
c "scripts/setup_nodes.exs"
# Choose option 1 (setup worker)
# Choose option 2 (connect to main)
```

### Terminal 1 - Run Remote Benchmark:

```elixir
c "scripts/benchmark.exs"
```

## 4. Troubleshooting

### "Worker pool queue full"

- Reduce concurrency: `--concurrency 25`
- Or increase `max_queue_size` in `config/config.exs`

### "No remote nodes connected!"

- Ensure nodes are started with `--name nodeX@127.0.0.1`
- Check: `Node.connect(:node2@127.0.0.1)` works
- Check firewalls aren't blocking Erlang distribution ports

### Function not found errors

- Run `mix run scripts/verify_setup.exs` first to set up test configs
- Check `ConfigDb` has the configs: `:ets.tab2list(:phoenix_gen_api_config_db)`

## 5. Customizing Benchmarks

Edit `scripts/benchmark.exs`:

- Change `setup_local_config()` to add your own FunConfigs
- Modify benchmark functions to test your specific use cases
- Adjust concurrency and request counts

## 6. Worker Pool Configuration

Current settings in `config/config.exs`:

```elixir
config :phoenix_gen_api, :worker_pool,
  async_pool_size: 1000,
  stream_pool_size: 500,
  max_queue_size: 10_000
```

To change:

1. Edit `config/config.exs`
2. Restart: `iex -S mix`
3. Verify: `PhoenixGenApi.pool_status()`

## 7. Need Help?

- Check `scripts/README.md` for full documentation
- Review `phoenix_gen_api/guides/` for PhoenixGenApi concepts
- Run `mix run scripts/verify_setup.exs` to diagnose issues
