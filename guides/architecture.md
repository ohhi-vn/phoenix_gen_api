# PhoenixGenApi — Architecture Deep Dive

## Table of Contents

1. [High-Level Overview](#1-high-level-overview)
2. [System Topology](#2-system-topology)
3. [Supervision Tree](#3-supervision-tree)
4. [Core Data Structures](#4-core-data-structures)
5. [Request Lifecycle](#5-request-lifecycle)
6. [Config Management](#6-config-management)
7. [Execution Engine](#7-execution-engine)
8. [Rate Limiter](#8-rate-limiter)
9. [Permission System](#9-permission-system)
10. [Worker Pools & Circuit Breakers](#10-worker-pools--circuit-breakers)
11. [Relay Messages](#11-relay-messages)
12. [Hooks](#12-hooks)
13. [Security](#13-security)
14. [Telemetry](#14-telemetry)
15. [Multi-Version Support](#15-multi-version-support)
16. [Retry & Fault Tolerance](#16-retry--fault-tolerance)
17. [Node Selection Strategies](#17-node-selection-strategies)

---

## 1. High-Level Overview

PhoenixGenApi is a framework for building API gateways on top of **Phoenix Channels** (WebSocket). Instead of defining HTTP endpoints, you define **function configurations** (`FunConfig`) that map WebSocket events to function calls — locally or remotely across an Elixir cluster.

```
┌──────────┐    WebSocket     ┌───────────────┐    RPC / Local     ┌──────────────┐
│  Browser  │ ◄─────────────► │  Gateway Node  │ ◄────────────────► │ Service Node │
│  Client   │  Phoenix Ch.    │  (Phoenix app) │    Erlang dist.    │  (your app)  │
└──────────┘                  └───────────────┘                    └──────────────┘
```

**Key design principles:**

- **Transport-agnostic business logic** — Your service functions don't know or care about WebSocket, JSON, or HTTP.
- **Cluster-native** — Services register their APIs on remote nodes; the gateway discovers them automatically via pull or push.
- **Zero HTTP boilerplate** — No controllers, no routers, no serializers. A `FunConfig` struct is the only thing between a WebSocket message and your function.
- **Defense in depth** — Rate limiting, permission checking, argument validation, MFA allowlists, and push tokens all layer together.

---

## 2. System Topology

There are two node roles:

### Gateway Node (Phoenix app)

- Runs the Phoenix web server and Channels.
- Holds the **ConfigDb** (ETS) cache of all registered `FunConfig` entries.
- Runs the **ConfigPuller** (periodic pull from services) and **ConfigReceiver** (accepts pushes).
- Runs the **RateLimiter**, **WorkerPoolSupervisor**, and **RelayServer**.
- Executes requests by looking up the `FunConfig`, checking rate limits/permissions, then calling the MFA (locally or via RPC).

### Service Node (any Elixir app)

- Runs your business logic (`MyApp.Api`).
- Optionally runs a **Supporter** module that returns `FunConfig` structs.
- Can **push** configs to the gateway on startup (`ConfigPusher`) or let the gateway **pull** them periodically.
- Sets `client_mode: true` to avoid starting gateway-only processes.

### Communication Flow

```
Service Node                          Gateway Node
    │                                      │
    │  1. Push configs (on startup)        │
    │─────────────────────────────────────►│  ConfigReceiver
    │                                      │
    │  2. Periodic pull (every 30s)        │
    │◄─────────────────────────────────────│  ConfigPuller
    │  3. Return FunConfig list             │
    │─────────────────────────────────────►│
    │                                      │
    │  4. Client sends WebSocket request   │
    │         ──────────────►               │  Channel
    │                                      │  Executor
    │  5. RPC to service node              │
    │◄─────────────────────────────────────│
    │  6. Return result                     │
    │─────────────────────────────────────►│
    │                                      │  7. Push result to client
    │         ◄──────────────               │
```

---

## 3. Supervision Tree

The application supervisor (`PhoenixGenApi.Supervisor`) uses a `:rest_for_one` strategy. If a child crashes, it and all children started after it are restarted.

```
PhoenixGenApi.Supervisor (:rest_for_one)
├── PhoenixGenApi.RateLimiter              (GenServer — ETS-backed sliding window)
├── PhoenixGenApi.WorkerPoolSupervisor     (Supervisor — :one_for_one)
│   ├── PhoenixGenApi.WorkerPool           (GenServer — async_pool)
│   │   └── [N x Worker]                  (GenServer — task execution)
│   └── PhoenixGenApi.WorkerPool           (GenServer — stream_pool)
│       └── [N x Worker]                  (GenServer — task execution)
├── PhoenixGenApi.ConfigDb                 (GenServer — ETS-backed FunConfig store)
├── PhoenixGenApi.ConfigPuller             (GenServer — periodic pull scheduler)
├── PhoenixGenApi.ConfigReceiver           (GenServer — push handler + version tracker)
├── PhoenixGenApi.RelayRegistry            (Registry — :duplicate keys, pid dispatch)
└── PhoenixGenApi.RelayServer              (GenServer — serializes ETS relay ops)
```

When `client_mode: true` (on service nodes), the supervisor starts **zero** children — the node only needs the library's structs and the `ConfigPusher` module (which is stateless).

---

## 4. Core Data Structures

### `FunConfig`

The central configuration unit. Each `FunConfig` maps one `request_type` to one function call.

```elixir
%FunConfig{
  request_type: "get_user",        # Unique identifier for this API endpoint
  service: "user_service",         # Service grouping key
  nodes: [:"node1@host"],          # Where to run (:local for gateway-local)
  choose_node_mode: :random,       # :random | :hash | :round_robin | {:hash, key} | {:sticky, key}
  timeout: 5_000,                  # RPC timeout in ms
  mfa: {MyApp.Api, :get_user, []}, # {Module, Function, Args} to call
  arg_types: %{"user_id" => :string},  # Argument validation schema
  arg_orders: ["user_id"],         # Ordered arg list (or :map for map-style)
  response_type: :sync,            # :sync | :async | :stream
  version: "1.0.0",                # Semantic version for multi-version support
  check_permission: false,         # false | :any_authenticated | {:arg, key} | {:role, roles}
  permission_callback: nil,        # Custom {mod, fun, args} for permission checks
  retry: nil,                      # nil | integer() | {:same_node, n} | {:all_nodes, n}
  before_execute: nil,             # {mod, fun} | {mod, fun, extra_args}
  after_execute: nil,              # {mod, fun} | {mod, fun, extra_args}
  disabled: false                  # Soft-delete flag
}
```

### `Request`

Created from the WebSocket payload by `Request.decode!/1`. Includes payload size validation (default 1MB), required field checks, and role sanitization.

```elixir
%Request{
  request_id: "req_123",    # Client-generated unique ID
  request_type: "get_user", # Matches FunConfig.request_type
  service: "user_service",  # Matches FunConfig.service
  user_id: "user_42",       # From socket.assigns or payload
  device_id: "device_1",    # From payload
  args: %{"user_id" => "42"}, # Function arguments
  user_roles: ["admin"],    # For role-based permissions
  version: "1.0.0"          # Optional version override
}
```

### `Response`

Returned to the client. Has constructors for each response type:

- `Response.sync_response(request_id, result)` — Standard success
- `Response.async_response(request_id)` — Acknowledged, processing async
- `Response.stream_response(request_id, result, has_more)` — Streaming chunk
- `Response.stream_end_response(request_id)` — Stream complete
- `Response.error_response(request_id, error, can_retry)` — Error

### `ServiceConfig`

Tells the `ConfigPuller` how to reach a service node and pull its configs.

```elixir
%ServiceConfig{
  service: "user_service",
  nodes: [:"node1@host"],
  module: MyApp.GenApi.Supporter,
  function: :get_config,
  args: [],
  version_module: MyApp.GenApi.Supporter,  # Optional: lightweight version check
  version_function: :get_config_version,
  version_args: []
}
```

### `PushConfig`

Used when a service node pushes its config to the gateway (instead of being pulled).

```elixir
%PushConfig{
  service: "user_service",
  nodes: [:"node1@host"],
  config_version: "1.2.3",
  fun_configs: [%FunConfig{...}],
  module: MyApp.GenApi.Supporter,  # Optional: for auto-pull after push
  function: :get_config,
  push_token: "secret"             # Authenticates push to gateway
}
```

---

## 5. Request Lifecycle

The complete path from WebSocket message to response:

```
Client                    Gateway Channel              Executor
  │                            │                          │
  │  push("api", payload)      │                          │
  │───────────────────────────►│                          │
  │                            │                          │
  │                     ┌──────┴──────┐                   │
  │                     │ handle_in/3 │                   │
  │                     │             │                   │
  │                     │ 1. Override │                   │
  │                     │    user_id  │                   │
  │                     │    from     │                   │
  │                     │    socket   │                   │
  │                     │    assigns  │                   │
  │                     │             │                   │
  │                     │ 2. Request  │                   │
  │                     │    .decode! │                   │
  │                     │    (valid.) │                   │
  │                     │             │                   │
  │                     │ 3. Execute  │                   │
  │                     └──────┬──────┘                   │
  │                            │                          │
  │                            │  Executor.execute!(req)  │
  │                            │─────────────────────────►│
  │                            │                          │
  │                            │                    ┌─────┴─────┐
  │                            │                    │ Phase 1:  │
  │                            │                    │ ConfigDb  │
  │                            │                    │ .get/3    │
  │                            │                    │ (ETS)     │
  │                            │                    └─────┬─────┘
  │                            │                          │
  │                            │                    ┌─────┴─────┐
  │                            │                    │ Phase 2:  │
  │                            │                    │ Hooks     │
  │                            │                    │ .run_     │
  │                            │                    │ before/3  │
  │                            │                    └─────┬─────┘
  │                            │                          │
  │                            │                    ┌─────┴─────┐
  │                            │                    │ Phase 3:  │
  │                            │                    │ RateLimit │
  │                            │                    │ + Perms   │
  │                            │                    └─────┬─────┘
  │                            │                          │
  │                            │                    ┌─────┴─────┐
  │                            │                    │ Phase 4-6:│
  │                            │                    │ sync /    │
  │                            │                    │ async /   │
  │                            │                    │ stream    │
  │                            │                    └─────┬─────┘
  │                            │                          │
  │                            │                    ┌─────┴─────┐
  │                            │                    │ Hooks     │
  │                            │                    │ .run_     │
  │                            │                    │ after/4   │
  │                            │                    └─────┬─────┘
  │                            │                          │
  │                            │  {:push, response}       │
  │                            │◄─────────────────────────│
  │                            │                          │
  │  push(socket, "api", resp) │                          │
  │◄───────────────────────────│                          │
```

### Phase Details

| Phase | Module | What Happens |
|-------|--------|-------------|
| **1** | `ConfigDb` | ETS lookup by `{service, request_type, version}`. Returns `{:ok, fun_config}`, `{:error, :not_found}`, or `{:error, :disabled}`. |
| **2** | `Hooks` | Runs `before_execute` hook (if configured) in a `Task` with timeout. Can abort with `{:error, reason}` or modify request/config. |
| **3a** | `RateLimiter` | Checks global limits and per-API limits using sliding window. Returns `{:error, :rate_limited, details}` if exceeded. |
| **3b** | `Permission` | Checks `check_permission` mode: disabled, authenticated, arg-based, role-based, or custom callback. |
| **4** | `Executor` | **Sync**: Calls MFA locally (`apply/3`) or remotely (`:rpc.call/5`). Supports retry with `{:same_node, n}` or `{:all_nodes, n}`. |
| **5** | `Executor` | **Async**: Spawns on `async_pool` worker. Sends `{:async_call, result}` back to the channel when done. |
| **6** | `Executor` | **Stream**: Starts a `StreamCall` GenServer on `stream_pool`. Sends `{:stream_response, result}` for each chunk. |
| **After** | `Hooks` | Runs `after_execute` hook (if configured). Can transform the result. |

---

## 6. Config Management

Config management follows a **pull** or **push** model (or both).

### Pull Model (Gateway-initiated)

The `ConfigPuller` GenServer runs on the gateway and periodically pulls configs from service nodes.

```
ConfigPuller (timer-based)
    │
    ├─ For each ServiceConfig:
    │   ├─ Optional: Call version_module.version_function on remote node
    │   │   └─ If version matches stored version → skip (saves bandwidth)
    │   │
    │   ├─ Call module.function(args) on remote node (RPC)
    │   │   └─ Returns list of FunConfig structs
    │   │
    │   ├─ Validate each FunConfig
    │   ├─ Enforce service name
    │   ├─ Ensure version field
    │   └─ ConfigDb.batch_add(configs) → ETS write
    │
    └─ Schedule next pull (with exponential backoff on failures)
```

**Version-based skip**: If `ServiceConfig.version_module` and `version_function` are set, the puller first makes a lightweight RPC to check if the version changed. If it matches the stored version, the full config pull is skipped entirely.

**Exponential backoff**: On pull failures, the interval increases (up to a cap) to avoid hammering unreachable nodes.

### Push Model (Service-initiated)

On service node startup, `ConfigPusher.push_on_startup/3` sends a `PushConfig` to the gateway's `ConfigReceiver`.

```
Service Node                          Gateway Node
    │                                      │
    │  ConfigPusher.push_on_startup        │
    │  (RPC to ConfigReceiver)             │
    │─────────────────────────────────────►│
    │                                      │
    │                               ┌──────┴──────┐
    │                               │ 1. Decode   │
    │                               │ 2. Validate │
    │                               │ 3. Check    │
    │                               │    version  │
    │                               │ 4. Check    │
    │                               │    push_tok │
    │                               │ 5. batch_add│
    │                               │ 6. Register │
    │                               │    puller   │
    │                               └──────┬──────┘
    │                                      │
    │  {:ok, :accepted}                    │
    │◄─────────────────────────────────────│
```

**Auto-pull registration**: A `PushConfig` can include `module`/`function` fields. After accepting the push, the `ConfigReceiver` registers the service with the `ConfigPuller` for periodic refresh — giving you push-on-startup + pull-for-refresh.

### ConfigDb (ETS Store)

`ConfigDb` is a GenServer wrapping an ETS table. The key is `{service, request_type, version}` and the value is the `FunConfig` struct.

Key operations:

| Function | Description |
|----------|-------------|
| `add/1` | Insert or replace a single `FunConfig` |
| `batch_add/1` | Atomic batch insert (all-or-nothing) |
| `get/3` | Lookup by `{service, request_type, version}` |
| `get_fast/2` | Lookup by `{service, request_type}` (any version, fastest path) |
| `get_latest/2` | Lookup the highest-versioned config for a request type |
| `update/1` | Update an existing config |
| `delete/3` | Remove a config |
| `disable/3` | Soft-delete (sets `disabled: true`) |
| `enable/3` | Re-enable a disabled config |
| `get_all_functions/0` | List all configs grouped by service |
| `clear/0` | Remove all configs |

---

## 7. Execution Engine

The `Executor` module is the heart of the framework. It handles three execution modes:

### Sync (`response_type: :sync`)

```
sync_call(request, fun_config)
    │
    ├─ If nodes == :local → execute_local(mfa, timeout)
    │                        └─ apply(mod, fun, args ++ [request_args])
    │
    └─ If nodes == [...]   → execute_remote_with_fallback(nodes, mfa, timeout)
                             ├─ Try node 1 → :rpc.call(node, mod, fun, args, timeout)
                             ├─ On failure → try node 2
                             └─ On all failures → return last error
```

**Retry logic** is configured per `FunConfig` via the `retry` field:

| Value | Behavior |
|-------|----------|
| `nil` | No retry (default) |
| `3` | Retry 3 times on the same node (local retry) |
| `{:same_node, 3}` | Retry 3 times on the same remote node |
| `{:all_nodes, 3}` | Retry on all nodes in the list, up to 3 total attempts |

**Backoff**: Exponential backoff between retries (`2^attempt * 100ms`, configurable).

### Async (`response_type: :async`)

```
async_call(request, fun_config)
    │
    ├─ WorkerPool.execute_async(:async_pool, fn ->
    │     result = Executor.sync_call(request, fun_config)
    │     send(receiver, {:async_call, result})
    │   end)
    │
    └─ Immediately returns async_response to client
```

The client receives an immediate `async: true` acknowledgment, then gets the actual result later via a `{:async_call, result}` message pushed to the channel.

### Stream (`response_type: :stream`)

```
stream_call(request, fun_config)
    │
    ├─ WorkerPool.execute_async(:stream_pool, fn ->
    │     StreamCall.start_link(...)
    │   end)
    │
    └─ StreamCall GenServer:
        ├─ Calls the MFA (which should return a stream/generator)
        ├─ Sends {:stream_response, chunk} for each intermediate result
        ├─ Sends {:stream_response, last_chunk, has_more: false} for the final result
        └─ Sends {:stream_response, stream_end} on completion
```

The stream process is tracked in the process dictionary under `{:phoenix_gen_api, :stream_call_pid, request_id}` and can be stopped with `PhoenixGenApi.stop_stream(request_id)`.

---

## 8. Rate Limiter

The `RateLimiter` uses a **sliding window** algorithm with ETS-backed counters.

### Architecture

```
RateLimiter (GenServer)
├── ETS table :rate_limiter_global   (key → [timestamps])
└── ETS table :rate_limiter_api      (key → [timestamps])
```

### Two Levels of Limits

1. **Global limits** — Apply across all requests. Configured as:
   ```elixir
   config :phoenix_gen_api, :rate_limiter,
     global_limits: [
       %{key: :user_id, max_requests: 1000, window_ms: 60_000}
     ]
   ```

2. **Per-API limits** — Apply to specific service/request_type pairs:
   ```elixir
   config :phoenix_gen_api, :rate_limiter,
     api_limits: [
       %{key: :user_id, service: "user_service", request_type: "get_user",
         max_requests: 100, window_ms: 60_000}
     ]
   ```

### Sliding Window Algorithm

For each request, the rate limiter:

1. Builds a composite key from the request (e.g., `"user_42"` for `:user_id` scope).
2. Looks up the ETS table for that key's timestamp list.
3. Removes timestamps outside the current window.
4. Counts remaining timestamps.
5. If count < max → appends current timestamp and allows.
6. If count ≥ max → rejects with `{:error, :rate_limited, details}`.

### Sharded Cleanup

A periodic cleanup process (`handle_info(:cleanup, ...)`) purges expired entries. The cleanup is **sharded** across rate limiter instances to avoid a single process scanning the entire table.

### Fail-Open

If the rate limiter itself encounters an error, it **fails open** (allows the request through) rather than blocking all traffic. This is configurable.

### Multi-Instance Support

For high-throughput deployments, multiple `RateLimiter` instances can run. Requests are routed to instances via consistent hashing on the key value.

---

## 9. Permission System

The permission system checks are performed **after** rate limiting but **before** execution.

### Permission Modes

| Mode | Config | Behavior |
|------|--------|----------|
| **Disabled** | `check_permission: false` | No permission check (default) |
| **Any authenticated** | `check_permission: :any_authenticated` | Requires `user_id` to be non-nil |
| **Arg-based** | `check_permission: {:arg, "user_id"}` | Compares `user_id` from socket to the value of the named arg |
| **Role-based** | `check_permission: {:role, ["admin", "moderator"]}` | Checks if any of the user's roles are in the allowed list |
| **Custom callback** | `permission_callback: {MyMod, :check, []}` | Calls the MFA; must return `:ok` or `{:error, reason}` |

### Arg-Based Permission Deep Dive

When `check_permission: {:arg, "user_id"}`, the system:

1. Finds the `"user_id"` value in the request args.
2. Compares it to the `user_id` from the socket assigns (set during channel join).
3. If they match → allow. If not → deny.

**Security note**: The `user_id` is always taken from `socket.assigns` (set during `join/3`), never from the client payload. This prevents a client from spoofing another user's identity.

### Role-Based Permission Deep Dive

When `check_permission: {:role, ["admin"]}`, the system:

1. Takes `user_roles` from the `Request` struct (populated from socket assigns).
2. Checks if any of the user's roles intersect with the allowed roles.
3. If intersection is non-empty → allow. Otherwise → deny.

### Custom Callback

```elixir
defmodule MyApp.Permissions do
  def check(request, fun_config) do
    if MyApp.authorized?(request.user_id, fun_config.request_type) do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end

# In FunConfig:
%FunConfig{
  check_permission: false,  # Disable built-in checks
  permission_callback: {MyApp.Permissions, :check, []}
}
```

When `permission_callback` is set, it **overrides** the `check_permission` field entirely.

---

## 10. Worker Pools & Circuit Breakers

### Architecture

```
WorkerPoolSupervisor (:one_for_one)
├── WorkerPool (:async_pool)
│   ├── Worker 1 (GenServer)
│   ├── Worker 2 (GenServer)
│   └── ... (default: 1000 workers)
└── WorkerPool (:stream_pool)
    ├── Worker 1 (GenServer)
    ├── Worker 2 (GenServer)
    └── ... (default: 500 workers)
```

### Task Flow

```
Executor.async_call/2
    │
    ├─ WorkerPool.execute_async(:async_pool, task_fn)
    │   │
    │   ├─ If idle worker exists → assign task immediately
    │   │   └─ Worker.execute(pid, task_fn)
    │   │       └─ spawn_link(fn -> task.() end)
    │   │       └─ On completion: send(pool, {:worker_done, self()})
    │   │
    │   ├─ If all workers busy → enqueue task
    │   │   └─ Queue (Erlang :queue module)
    │   │   └─ If queue full → reject with {:error, :queue_full}
    │   │
    │   └─ On {:worker_done}:
    │       ├─ Mark worker as idle
    │       └─ Dequeue next task → assign to this worker
    │
    └─ Circuit breaker check (pool-level + worker-level)
```

### Circuit Breaker

Both the pool and individual workers have circuit breakers:

**Pool-level**: Tracks consecutive failures across all workers. If failures exceed `circuit_breaker_threshold` (default: 10), the pool opens and rejects new tasks for `circuit_breaker_cooldown` ms (default: 60s).

**Worker-level**: Each worker tracks its own consecutive failures. If failures exceed the threshold (default: 5), that individual worker stops accepting tasks for the cooldown period.

```
Normal:    [task] → [worker] → success/failure → reset counter on success
              │
              └── failures accumulate ──► threshold reached ──► CIRCUIT OPEN
              │                                                      │
              │                                              Reject all tasks
              │                                              for cooldown period
              │                                                      │
              └── success during cooldown ───► CIRCUIT CLOSE ◄───────┘
```

---

## 11. Relay Messages

The relay system enables group-based message broadcasting. A user sends a message to a group, and all members receive it through their Phoenix Channel.

### Architecture

```
RelayServer (GenServer — serializes ETS writes)
├── ETS table :phoenix_gen_api_relay_groups
│   └── {group_id, group_type, members_map}
│
├── Registry (PhoenixGenApi.RelayRegistry, :duplicate keys)
│   └── {group_id} → [{user_id, channel_pid}, ...]
│
└── Process monitors
    └── {{group_id, user_id} → monitor_ref}
```

### Group Types

| Type | Join | Accept | Send | Mute |
|------|------|--------|------|------|
| `:public` | → `:active` | N/A | Any `:active` | ❌ |
| `:private` | → `:pending` | Any `:active` | Any `:active` | ❌ |
| `:strict_private` | → `:pending` | Only `:admin` | Any `:active` (not muted) | Only `:admin` |

### Message Flow

```
Client A (channel)          RelayServer              Client B (channel)
      │                          │                          │
      │  push("api", payload)    │                          │
      │─────────────────────────►│                          │
      │                          │                          │
      │                   ┌──────┴──────┐                   │
      │                   │ handle_relay │                   │
      │                   │             │                   │
      │                   │ 1. Validate │                   │
      │                   │    member   │                   │
      │                   │ 2. Check    │                   │
      │                   │    not muted│                   │
      │                   │ 3. Registry │                   │
      │                   │    .select  │                   │
      │                   │ 4. send(pid,│                   │
      │                   │  {:relay_   │                   │
      │                   │  message})  │                   │
      │                   └──────┬──────┘                   │
      │                          │                          │
      │  {:relay_message, resp}  │  {:relay_message, resp}  │
      │◄─────────────────────────│─────────────────────────►│
      │                          │                          │
      │  handle_info → push      │         handle_info → push
```

### Auto-Cleanup via Process Monitoring

`RelayServer` monitors every channel process that joins a group. When a channel process dies (client disconnect, crash, etc.), the `RelayServer` receives a `{:DOWN, ...}` message and automatically removes the user from the group — cleaning up both the ETS entry and the Registry entry.

---

## 12. Hooks

Hooks let you run custom code before and/or after function execution without modifying the function itself.

### Hook Lifecycle

```
Executor.execute_with_config!
    │
    ├─ Hooks.run_before(before_execute, request, fun_config)
    │   ├─ nil → skip
    │   ├─ {mod, fun} → Task.async(fn -> apply(mod, fun, [request, fun_config]) end)
    │   ├─ {mod, fun, extra} → Task.async(fn -> apply(mod, fun, [request, fun_config | extra]) end)
    │   │
    │   ├─ Task.yield(task, timeout)  # default 5s timeout
    │   │   ├─ {:ok, {:ok, new_req, new_config}} → proceed with modified values
    │   │   ├─ {:ok, {:error, reason}} → abort, return error response
    │   │   ├─ nil (timeout) → log error, return timeout error
    │   │   └─ {:exit, reason} → log error, return crash error
    │   │
    │   └─ Telemetry: [:hook, :before, :start/:stop/:exception]
    │
    ├─ [execute the function — sync/async/stream]
    │
    └─ Hooks.run_after(after_execute, request, fun_config, result)
        ├─ nil → skip
        ├─ {mod, fun} → Task.async(fn -> apply(mod, fun, [request, fun_config, result]) end)
        │
        ├─ Task.yield(task, timeout)
        │   ├─ {:ok, new_result} → use modified result
        │   └─ {:error, _} → preserve original result
        │
        └─ Telemetry: [:hook, :after, :start/:stop/:exception]
```

### Common Use Cases

- **Before**: Quota checking, request enrichment, audit logging, feature flags.
- **After**: Response transformation, metrics emission, cache invalidation, audit trails.

---

## 13. Security

PhoenixGenApi has multiple security layers:

### 1. Admin Gate

Dangerous runtime operations (updating rate limit config, pushing configs, toggling detail errors) require the action to be in the `:admin_actions` allowlist:

```elixir
config :phoenix_gen_api,
  admin_actions: [:push_config, :update_rate_limit_config]
```

Default: empty list (deny everything).

### 2. Push Token

When `:push_token` is configured, all push requests must include a matching token. Comparison uses constant-time binary comparison to prevent timing attacks.

```elixir
config :phoenix_gen_api, push_token: "my-secret-token"
```

### 3. MFA Allowlist

Restricts which `{module, function}` pairs can be registered as function configs. Supports module-level (all functions) and tuple-level (specific function) entries.

```elixir
config :phoenix_gen_api,
  mfa_allowlist: [
    MyApp.UserService,                    # All functions allowed
    {MyApp.OrderService, :create_order}   # Only this specific function
  ]
```

**Hardcoded denylist**: `:os`, `:file`, `:code`, `:erlang`, `:net`, `:rpc`, `:global`, `:inet` are always blocked unless explicitly allowed.

### 4. Payload Size Limit

`Request.decode!/1` validates payload size before deserialization (default: 1MB). Prevents memory exhaustion attacks.

```elixir
config :phoenix_gen_api, :request, max_payload_bytes: 500_000
```

### 5. User ID Override Prevention

The channel's `handle_in/3` always takes `user_id` from `socket.assigns` (set during `join/3`), never from the client payload. This prevents impersonation.

---

## 14. Telemetry

PhoenixGenApi emits telemetry events at every stage of the request lifecycle. All events follow the pattern `[:phoenix_gen_api, category, ...]`.

### Event Categories

| Category | Events |
|----------|--------|
| **Executor** | `:request → :start/:stop/:exception`, `:retry`, `:retry → :exhausted` |
| **Rate Limiter** | `:check`, `:exceeded`, `:reset`, `:cleanup` |
| **Hooks** | `:before/:after → :start/:stop/:exception` |
| **Worker Pool** | `:task → :start/:stop/:exception/:rejected`, `:circuit_breaker → :open/:close` |
| **Config** | `:pull → :start/:stop`, `:push`, `:add`, `:batch_add`, `:delete`, `:clear`, `:disable`, `:enable` |

### Attaching Handlers

```elixir
# Attach to all events
PhoenixGenApi.Telemetry.attach_all("my-app", &MyApp.handle_event/4)

# Attach to specific categories
PhoenixGenApi.Telemetry.attach_executor("my-app-exec", &MyApp.handle_event/4)
PhoenixGenApi.Telemetry.attach_rate_limiter("my-app-rl", &MyApp.handle_event/4)
PhoenixGenApi.Telemetry.attach_hooks("my-app-hooks", &MyApp.handle_event/4)
PhoenixGenApi.Telemetry.attach_worker_pool("my-app-wp", &MyApp.handle_event/4)
PhoenixGenApi.Telemetry.attach_config("my-app-cfg", &MyApp.handle_event/4)

# Built-in debug logger
PhoenixGenApi.Telemetry.attach_default_logger()

# Detach
PhoenixGenApi.Telemetry.detach_all("my-app")
```

---

## 15. Multi-Version Support

A single `request_type` can have multiple `FunConfig` entries with different versions. The version is resolved at request time:

```
Client sends: %{request_type: "get_user", version: "2.0.0"}
    │
    ├─ If version is specified → ConfigDb.get(service, "get_user", "2.0.0")
    │
    └─ If version is nil → ConfigDb.get(service, "get_user", "0.0.0")
                              └─ "0.0.0" is the default/sentinel version
```

**Version management**:

- Add a new version: `ConfigDb.add(%FunConfig{..., version: "2.0.0"})`
- Disable an old version: `ConfigDb.disable("user_service", "get_user", "1.0.0")`
- Re-enable: `ConfigDb.enable("user_service", "get_user", "1.0.0")`
- Delete: `ConfigDb.delete("user_service", "get_user", "1.0.0")`

The `"0.0.0"` version is a **reserved sentinel** — it cannot be explicitly registered and serves as the default when no version is specified.

---

## 16. Retry & Fault Tolerance

### Retry Configuration

```elixir
# In FunConfig:
%FunConfig{
  retry: 3,                    # Retry 3 times (local)
  retry: {:same_node, 3},      # Retry 3 times on the same remote node
  retry: {:all_nodes, 3}       # Retry across all nodes, 3 total attempts
}
```

### Retry Flow (Remote)

```
execute_remote_with_fallback([node1, node2, node3], mfa, timeout)
    │
    ├─ Try node1 → :rpc.call(node1, ...)
    │   ├─ Success → return result
    │   └─ Failure → check retry config
    │       ├─ {:same_node, n} → retry node1 (n-1) times with backoff
    │       ├─ {:all_nodes, n} → try node2, then node3
    │       └─ nil → try node2 (no retry, just fallback)
    │
    ├─ Try node2 → ...
    │
    └─ All nodes failed → return last error
```

### Node Fallback

Even without retry, the executor will try all nodes in the `nodes` list before giving up. This provides basic failover when a service node goes down.

### Exponential Backoff

Between retries, the executor waits `2^attempt * base_ms` milliseconds (configurable). This prevents thundering herd problems during recovery.

---

## 17. Node Selection Strategies

When a `FunConfig` has multiple nodes, the `NodeSelector` picks one:

| Strategy | Config | Behavior |
|----------|--------|----------|
| `:random` | `choose_node_mode: :random` | Pick a random node (default) |
| `:hash` | `choose_node_mode: :hash` | Hash the `request_id` to pick a node |
| `{:hash, key}` | `choose_node_mode: {:hash, "user_id"}` | Hash the value of the named arg |
| `:round_robin` | `choose_node_mode: :round_robin` | Cycle through nodes in order |
| `{:sticky, key}` | `choose_node_mode: {:sticky, "user_id"}` | Same key value always maps to the same node (using ETS for persistence) |

### Sticky Routing Deep Dive

Sticky routing ensures that all requests with the same key value (e.g., same `user_id`) always go to the same node. This is useful for:

- Cache locality (user data is cached on one node)
- Session affinity
- Ordered processing per user

Implementation: An ETS table stores `{key_value, node}` mappings. On lookup, if the key exists and the node is still alive, it's reused. If not, a new node is selected and stored.

```elixir
# Cleanup stale entries (called periodically)
NodeSelector.cleanup_sticky_table()
```

### Dynamic Node Resolution

Nodes can be specified as a static list or as an MFA tuple that resolves at runtime:

```elixir
# Static:
nodes: [:"node1@host", :"node2@host"]

# Dynamic (called on each node selection):
nodes: {MyApp.Cluster, :get_nodes, ["user_service"]}
```

This allows integration with service discovery systems.

---

## What's Next

- **[FunConfig Reference](./fun_config.md)** — Field-by-field reference for the central configuration struct.
- **[Configuration](./configuration.md)** — Full application-level configuration reference.
- **[Step-by-Step Guide](./step_by_step_guide.md)** — Every feature with copy-paste code examples.
- **[Execute Flow](./execute_flow.md)** — Line-by-line walkthrough of the complete request execution path.
- **[Relay Messages Guide](./relay_messages.md)** — Complete reference for group-based messaging.
- **[Telemetry Guide](./telemetry.md)** — Full event reference and integration patterns.
