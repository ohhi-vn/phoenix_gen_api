[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/phoenix_gen_api)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_gen_api.svg?style=flat&color=blue)](https://hex.pm/packages/phoenix_gen_api)

# PhoenixGenApi

A framework for rapidly building backend APIs on top of Phoenix Channels and Erlang clustering. Define your business logic on any node — the framework handles routing, validation, permissions, retries, and observability. No HTTP endpoints to write, no routes to configure, no restarts to deploy.

**Version**: 2.18.0 | **Elixir**: ~> 1.18 | **OTP**: ~> 27 | **License**: MPL-2.0

## Why PhoenixGenApi?

Traditional Phoenix backends require you to: define routes, write controllers, serialize responses, handle errors, and restart to deploy changes. PhoenixGenApi eliminates all of that:

- **No routes, no controllers** — Clients call functions by name over WebSocket. The framework routes requests to the right node automatically.
- **No restarts to deploy** — Register new APIs at runtime from any cluster node. The gateway picks them up instantly (push) or on the next pull interval.
- **Built-in cross-cutting concerns** — Permissions, rate limiting, retries, circuit breakers, hooks, and telemetry come standard. No plugs, no middleware.
- **Multi-node by default** — Erlang distribution means your APIs run across the cluster. The framework handles node selection, RPC, and failover.
- **Real-time ready** — Async responses, streaming, and relay messages (group chat) are first-class features, not afterthoughts.

## How It Works

```text
┌──────────┐     WebSocket      ┌──────────────────┐     RPC      ┌──────────────┐
│  Client  │ ◄──────────────► │  Phoenix Gateway  │  ◄─────────► │ Service Node │
└──────────┘   (Phoenix Ch.)   │  (uses this lib)  │   (Erlang)   │  (your app)  │
                               └──────────────────┘              └──────────────┘
```

1. **Clients** send requests through a Phoenix Channel.
2. The **Gateway** looks up the matching `FunConfig`, selects a node, validates arguments & permissions, then executes the remote function.
3. The **Service Node** runs the function and returns the result.

Service nodes can register new APIs at any time — the gateway picks them up automatically (pull) or receives them immediately (push).

## Features

| Feature | Description |
|---------|-------------|
| **Dynamic Configuration** | Add, update, or remove APIs at runtime from any cluster node |
| **Response Modes** | Sync, async, streaming, and fire-and-forget |
| **Node Selection** | Random, hash-based, round-robin, sticky, or custom strategies |
| **Function Versioning** | Run multiple API versions side-by-side; enable/disable per version |
| **Rate Limiting** | Sliding-window rate limiter with global and per-API limits |
| **Permissions** | Authenticated-only, argument-based, role-based, or custom callback |
| **Retry** | Configurable retry on same node or across all nodes, with exhaustion telemetry |
| **Hooks** | `before_execute` / `after_execute` callbacks with per-hook timeout protection |
| **Relay Messages** | Group-based message relaying with automatic cleanup on disconnect |
| **Circuit Breaker** | Pool-level and worker-level circuit breakers |
| **Telemetry** | 31 events across 5 categories for observability |
| **Security** | Admin gate, push tokens, MFA allowlist, payload size limits |
| **Diagnostics** | Runtime health checks, statistics, call-flow inspection, cluster view, admin-gated tracing |

## Installation

```elixir
def deps do
  [
    {:phoenix_gen_api, "~> 2.16"}
  ]
end
```

Use [`:libcluster`](https://hex.pm/packages/libcluster) to form the Erlang cluster.

## Documentation

| Guide | Description |
|---|---|
| [Getting Started](guides/getting_started.md) | Build a working API gateway in 10 minutes with a Phoenix gateway and service node |
| [Step-by-Step Guide](guides/step_by_step_guide.md) | Every feature explained with copy-paste code examples: validation, permissions, rate limiting, async, streaming, hooks, relay, security, telemetry |
| [FunConfig Reference](guides/fun_config.md) | Field-by-field reference for the central configuration struct |
| [Configuration](guides/configuration.md) | Full configuration reference: gateway, rate limiter, worker pool, security |
| [Architecture](guides/architecture.md) | Deep dive into the supervision tree, request lifecycle, config management, execution engine, and all subsystems |
| [Execute Flow](guides/execute_flow.md) | Line-by-line walkthrough of the complete request execution path with file references |
| [Relay Messages](guides/relay_messages.md) | Complete reference for group-based messaging: group types, permission matrix, process monitoring |
| [Telemetry](guides/telemetry.md) | Full event reference, integration patterns, Telemetry.Metrics examples, and best practices |
| [Diagnostics](guides/diagnostics.md) | Runtime health checks, statistics, call-flow inspection, cluster view, admin-gated tracing, IEx helpers |

## Quick Start

Define your API on the service node:

```elixir
defmodule MyApp.Api do
  def get_user(user_id) do
    %{id: user_id, name: "Alice"}
  end
end
```

Create a `FunConfig` and register it on the gateway (pull mode):

```elixir
# On the service node — define a supporter
defmodule MyApp.GenApi.Supporter do
  def get_config(_arg) do
    {:ok, [%PhoenixGenApi.Structs.FunConfig{
      request_type: "get_user",
      service: "user_service",
      nodes: [Node.self()],
      mfa: {MyApp.Api, :get_user, []},
      arg_types: %{"user_id" => :string},
      response_type: :sync
    }]}
  end
end

# On the gateway — configure the puller
config :phoenix_gen_api, :gen_api,
  service_configs: [%{
    service: "user_service",
    nodes: [:"app@host"],
    module: MyApp.GenApi.Supporter,
    function: :get_config,
    args: []
  }]
```

Add PhoenixGenApi to your Channel:

```elixir
defmodule MyAppWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"
end
```

Call from the client:

```json
{
  "service": "user_service",
  "request_type": "get_user",
  "request_id": "req_1",
  "args": { "user_id": "123" }
}
```

That's it — you have a working API gateway. See the [Getting Started](guides/getting_started.md) guide for the full 2-node walkthrough.

## IEx Helpers

```elixir
PhoenixGenApi.rl_status("user_123")     # Rate limit status
PhoenixGenApi.rl_global()               # Global rate limits
PhoenixGenApi.rl_config()               # Rate limiter config
PhoenixGenApi.cache_status()            # Config cache status
PhoenixGenApi.pool_status()             # Worker pool status
PhoenixGenApi.pushed_services_status()  # Pushed services status

# Diagnostics & Monitoring
PhoenixGenApi.health_check()              # Runtime health report
PhoenixGenApi.health_check(max_memory_bytes: 100_000_000)
PhoenixGenApi.statistics()               # VM & PhoenixGenApi statistics
PhoenixGenApi.debug_report(process_limit: 10)  # Top processes, ETS tables
PhoenixGenApi.call_flow("user_service", "get_user")  # Trace request flow
PhoenixGenApi.cluster_view()             # Cluster topology
PhoenixGenApi.list_call_flows()          # All registered call flows
```

### IEx Print Helpers

For quick console output, use the `*_print` variants:

```elixir
# Print formatted health check to console
PhoenixGenApi.health_print()

# Print formatted statistics to console
PhoenixGenApi.stats_print()

# Print formatted debug report to console
PhoenixGenApi.debug_print(process_limit: 10)

# Print formatted call flow trace to console
PhoenixGenApi.call_flow_print("user_service", "get_user")

# Print formatted cluster topology to console
PhoenixGenApi.cluster_print()

# Print formatted list of all call flows to console
PhoenixGenApi.flows_print()

# Print formatted request inspection to console
PhoenixGenApi.inspect_print(%{service: "user_service", request_type: "get_user"})

# Failed config tracking (24h TTL)
PhoenixGenApi.failed_configs()                    # List failed configs
PhoenixGenApi.failed_configs(source: :pull)       # Filter by source
PhoenixGenApi.failed_configs_print()               # Print formatted table
PhoenixGenApi.failed_configs_summary()             # Print summary
PhoenixGenApi.cleanup_failed_configs()             # Clean expired entries
```

## Failed Config Tracking

PhoenixGenApi automatically tracks FunConfig entries that fail validation during
pull or push. Entries are stored in an ETS table with a 24-hour TTL and include
the config, failure reason, source (:pull or :push), and originating node.

```elixir
# List all failed entries
PhoenixGenApi.failed_configs()

# Filter by source
PhoenixGenApi.failed_configs(source: :pull)
PhoenixGenApi.failed_configs(source: :push, limit: 20)

# Print formatted table to console
PhoenixGenApi.failed_configs_print()

# Print summary (counts by source, by service)
PhoenixGenApi.failed_configs_summary()

# Clean up expired entries (older than 24h)
PhoenixGenApi.cleanup_failed_configs()

# Clear all entries
PhoenixGenApi.clear_failed_configs()
```

## Diagnostics & Tracing

For runtime debugging, PhoenixGenApi provides admin-gated tracing:

```elixir
# Configure admin actions
config :phoenix_gen_api, :admin_actions, [
  :enable_tracing,
  :disable_tracing
]

# Trace processes
PhoenixGenApi.trace_processes(:all, flags: [:call, :procs])
PhoenixGenApi.stop_trace(:all)

# Trace specific functions
PhoenixGenApi.trace_functions({MyApp.Api, :get_user, 1})
PhoenixGenApi.stop_trace_functions(:all)
```

See the [Diagnostics Guide](guides/diagnostics.md) for full documentation.

## Related Packages

| Package | Description |
|---|---|
| [PhoenixGenApi](https://hex.pm/packages/phoenix_gen_api) | Core library — dynamic API gateway over Phoenix Channels |
| [EasyRpc](https://hex.pm/packages/easy_rpc) | Wrap RPC calls from remote nodes so they can be used like local functions |
| [ClusterHelper](https://hex.pm/packages/cluster_helper) | Dynamic cluster node discovery |
| [ToonEx](https://hex.pm/packages/toon_ex) | TOON encoder/decoder — compact binary protocol for Phoenix Channels |
| [AshPhoenixGenApi](https://hex.pm/packages/ash_phoenix_gen_api) | Ash extension that auto-generates `FunConfig` from Ash resources |

## AI Agent Support

```bash
mix usage_rules.sync AGENTS.md --all --link-to-folder deps --inline usage_rules:all
mix tidewave
```

Connect at `http://localhost:4114/tidewave/mcp`. See [Tidewave](https://hexdocs.pm/tidewave/) for details.
