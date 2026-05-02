# PhoenixGenApi Benchmark Scripts

This directory contains scripts for benchmarking PhoenixGenApi performance with local and remote node execution.

## Files

- `benchmark.exs` - Main benchmark script
- `setup_nodes.exs` - Helper for setting up multi-node environment

## Prerequisites

- Elixir installed
- PhoenixGenApi project set up and compiled
- For remote benchmarks: Multiple nodes that can connect to each other

## Quick Start

### Local Benchmark Only

```bash
cd /path/to/phoenix_gen_api
mix run scripts/benchmark.exs -- --mode local
```

### Remote Benchmark (Multi-Node)

#### Step 1: Start the Main Node

```bash
cd /path/to/phoenix_gen_api
iex --name main@127.0.0.1 -S mix
```

In the iex shell:
```elixir
# Verify PhoenixGenApi is running
PhoenixGenApi.pool_status()
```

#### Step 2: Start Worker Node(s)

In a new terminal:
```bash
cd /path/to/phoenix_gen_api
iex --name node2@127.0.0.1 -S mix
```

In the worker node's iex shell:
```elixir
# Run the setup script
mix run scripts/setup_nodes.exs
# Choose option 1 to set up as worker
# Then option 2 to connect to main node
```

#### Step 3: Run Remote Benchmark

Back on the main node:
```bash
# In the main node iex shell
mix run scripts/benchmark.exs -- --mode remote --concurrency 100 --requests 1000
```

## Benchmark Options

### benchmark.exs Options

| Option | Alias | Default | Description |
|--------|--------|---------|-------------|
| `--mode` | `-m` | `both` | Benchmark mode: `local`, `remote`, or `both` |
| `--concurrency` | `-c` | `50` | Number of concurrent workers |
| `--requests` | `-r` | `1000` | Total number of requests to send |

### Examples

```bash
# Local benchmark with 100 concurrent workers, 2000 total requests
mix run scripts/benchmark.exs -- --mode local --concurrency 100 --requests 2000

# Remote benchmark with default settings
mix run scripts/benchmark.exs -- --mode remote

# Both local and remote benchmarks
mix run scripts/benchmark.exs
```

## What Gets Benchmarked

### Local Execution
- **Sync calls**: Direct function execution on local node
- **Async calls**: Execution via worker pool (async_pool)
- **Mixed workload**: Combination of sync and async calls

### Remote Execution
- **Sync calls (remote)**: RPC calls to remote nodes
- **Async calls (remote)**: Async execution on remote nodes via worker pool
- **Node fallback**: Behavior when nodes fail (simulated)

## Sample Output

```
============================================================
PhoenixGenApi Benchmark
============================================================
Mode: :local
Concurrency: 50
Requests per worker: 20
Total requests: 1000
============================================================

Worker Pool Status:
  Async pool: %{busy_workers: 0, circuit_open: false, ...}
  Stream pool: %{busy_workers: 0, circuit_open: false, ...}

------------------------------------------------------------
LOCAL EXECUTION BENCHMARKS
------------------------------------------------------------

📊 Benchmark: Sync calls (local)
----------------------------------------
  Total requests: 1000
  Time: 1234.5ms
  Throughput: 810.23 req/sec
  Avg latency: 1.23ms

📊 Benchmark: Async calls (local)
----------------------------------------
  Total requests: 1000
  Time: 2345.6ms
  Throughput: 426.32 req/sec

...
```

## Understanding Results

### Metrics

- **Throughput (req/sec)**: Higher is better. Measures how many requests per second the system can handle.
- **Avg latency (ms)**: Lower is better. Measures the average time per request.
- **Time (ms)**: Total time taken for all requests.

### Factors Affecting Performance

1. **Worker Pool Size**: Configured in `config/config.exs`
   - `async_pool_size`: 1000 (default)
   - `stream_pool_size`: 500 (default)
   - `max_queue_size`: 10,000 (default)

2. **Concurrency Level**: Higher concurrency can improve throughput but may increase latency.

3. **Network Latency**: Remote calls will be slower due to network overhead.

4. **Function Complexity**: The benchmark uses a simple echo function. Real functions may be slower.

## Troubleshooting

### "No remote nodes connected!"

Make sure:
1. Worker nodes are started with `--name nodeX@127.0.0.1`
2. Worker nodes have connected to the main node via `Node.connect/1`
3. Firewalls are not blocking the Erlang distribution ports

### "PhoenixGenApi not running"

On each node, ensure PhoenixGenApi is started:
```elixir
PhoenixGenApi.start_link()
```

### Worker pool queue full errors

Increase the `max_queue_size` in `config/config.exs` or reduce concurrency.

## Customization

To benchmark your own functions:

1. Add your FunConfig to the `setup_local_config/0 or `setup_remote_config/1` functions in `benchmark.exs`
2. Modify the request creation in the benchmark functions
3. Run the benchmark

## License

Same as PhoenixGenApi project.
