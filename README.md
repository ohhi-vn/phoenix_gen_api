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
│  Client  │ ◄──────────────► │  Phoenix Gateway  │ ◄──────────► │ Service Node │
└──────────┘   (Phoenix Ch.)   │  (uses this lib)  │   (Erlang)   │  (your app)  │
                               └──────────────────┘              └──────────────┘
```

1. **Clients** send requests through a Phoenix Channel.
2. The **Gateway** looks up the matching `FunConfig`, selects a node, validates arguments & permissions, then executes the remote function.
3. The **Service Node** runs the function and returns the result.

Service nodes can register new APIs at any time — the gateway picks them up automatically (pull) or receives them immediately (push).

## Features

- **Dynamic Configuration** — Add, update, or remove APIs at runtime from any cluster node
- **Multiple Response Modes** — Sync, async, streaming, and fire-and-forget
- **Node Selection** — Random, hash-based, round-robin, or custom strategies
- **Function Versioning** — Run multiple API versions side-by-side; enable/disable per version
- **Rate Limiting** — Sliding-window rate limiter with global and per-API limits
- **Permission System** — Authenticated-only, argument-based, or role-based access control
- **Retry** — Configurable retry on the same node or across all nodes, with exhaustion telemetry
- **Hooks** — `before_execute` / `after_execute` callbacks with per-hook timeout protection (default 5s)
- **Telemetry** — 31 events across 5 categories for observability
- **Relay Messages** — Group-based message relaying with automatic cleanup on channel disconnect
- **Circuit Breaker** — Configurable pool-level and worker-level circuit breakers
- **Structured Errors** — `Request.decode!/1` returns structured error codes (`:invalid_payload`, `:missing_field`)

## Installation

Requires Elixir ~> 1.18 and OTP ~> 27.

```elixir
def deps do
  [
    {:phoenix_gen_api, "~> 2.16"}
  ]
end
```

Use [`:libcluster`](https://hex.pm/packages/libcluster) to form the Erlang cluster.

## Quick Start

### 1. Define your API on the service node

```elixir
defmodule MyApp.Api do
  def get_user(user_id) do
    %{id: user_id, name: "Alice"}
  end
end
```

### 2. Create a FunConfig

A `FunConfig` tells the gateway *how* to call your function:

```elixir
alias PhoenixGenApi.Structs.FunConfig

%FunConfig{
  request_type: "get_user",
  service: "user_service",
  nodes: [:"app@host"],
  choose_node_mode: :random,
  timeout: 5_000,
  mfa: {MyApp.Api, :get_user, []},
  arg_types: %{"user_id" => :string},
  response_type: :sync,
  version: "1.0.0"
}
```

### 3. Register the config on the gateway

**Option A — Pull mode** (gateway fetches from service node on startup):

On the service node, define a supporter module:

```elixir
defmodule MyApp.GenApi.Supporter do
  alias PhoenixGenApi.Structs.FunConfig

  def get_config(_arg) do
    {:ok, [
      %FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyApp.Api, :get_user, []},
        arg_types: %{"user_id" => :string},
        response_type: :sync,
        version: "1.0.0"
      }
    ]}
  end
end
```

Then configure the gateway to pull from it (see [Gateway Configuration](#gateway-configuration) below).

**Option B — Push mode** (service node pushes to gateway on startup):

```elixir
alias PhoenixGenApi.ConfigPusher

fun_configs = [%FunConfig{ ... }]

push_config = ConfigPusher.from_service_config(
  :user_service,
  [Node.self()],
  fun_configs,
  config_version: "1.0.0"
)

ConfigPusher.push_on_startup(:"gateway@host", push_config)
```

**Option C — Add directly** on the gateway node at runtime:

```elixir
PhoenixGenApi.ConfigDb.add(%FunConfig{ ... })
```

### 4. Add PhoenixGenApi to your Channel

```elixir
defmodule MyAppWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"

  # handle_in, handle_info for :push, :async_call, :stream_response
  # are automatically injected by `use PhoenixGenApi`
end
```

### 5. Call from the client

Send a JSON message over the channel:

```json
{
  "service": "user_service",
  "request_type": "get_user",
  "request_id": "req_1",
  "args": { "user_id": "123" }
}
```

Receive the response:

```json
{
  "request_id": "req_1",
  "result": { "id": "123", "name": "Alice" },
  "success": true,
  "async": false,
  "has_more": false
}
```

That's it — you have a working API gateway.

---

## Core Concepts

### FunConfig

`FunConfig` is the central data structure. It maps a `{service, request_type}` pair to a function call.

| Field | Type | Description |
|---|---|---|
| `request_type` | `String.t()` | API endpoint name (e.g. `"get_user"`) |
| `service` | `atom \| String.t()` | Service group name (e.g. `"user_service"`) |
| `nodes` | `[atom] \| {m, f, a} \| :local` | Target nodes or `:local` for same-node execution |
| `choose_node_mode` | `:random \| :hash \| {:hash, key} \| :round_robin` | Node selection strategy |
| `timeout` | `integer \| :infinity` | Execution timeout in ms (100–300 000 or `:infinity`) |
| `mfa` | `{module, function, args}` | The function to call. Args are prepended with converted request args |
| `arg_types` | `%{name => type}` | Argument type declarations for validation |
| `arg_orders` | `[String.t()] \| :map` | Argument ordering (or `:map` to pass a map) |
| `response_type` | `:sync \| :async \| :stream \| :none` | How the result is delivered |
| `check_permission` | `false \| :any_authenticated \| {:arg, name} \| {:role, roles}` | Permission mode |
| `permission_callback` | `{m, f, a} \| nil` | Custom permission check |
| `request_info` | `boolean()` | Pass the full `%Request{}` as first arg to the MFA (legacy field, currently unused in execution) |
| `version` | `String.t() \| nil` | API version (default `nil`). `"0.0.0"` is reserved as a sentinel and cannot be explicitly registered |
| `disabled` | `boolean()` | Disable this version without removing it |
| `retry` | `nil \| number \| {:same_node, n} \| {:all_nodes, n}` | Retry configuration |
| `before_execute` | `{m, f} \| {m, f, a} \| nil` | Hook called before execution |
| `after_execute` | `{m, f} \| {m, f, a} \| nil` | Hook called after execution |
| `hook_timeout` | `positive_integer()` | Per-hook timeout in ms (default `5_000`). Prevents misbehaving hooks from blocking requests |

### Request

The client payload is decoded into a `%Request{}`:

| Field | Type | Description |
|---|---|---|
| `user_id` | `String.t() \| nil` | Authenticated user ID (can be set from socket assigns) |
| `device_id` | `String.t() \| nil` | Device identifier |
| `request_type` | `String.t()` | Which API to call |
| `request_id` | `String.t()` | Client-generated ID to match responses |
| `service` | `String.t()` | Target service |
| `args` | `map()` | Request arguments |
| `user_roles` | `[String.t()] \| nil` | User roles for RBAC |
| `version` | `String.t() \| nil` | Requested API version (nil means no version specified) |

`Request.decode!/1` validates the payload before deserialization:

- **Payload size** is checked before deserialization (default limit: 1MB, configurable via `config :phoenix_gen_api, :request, max_payload_bytes: N`)
- **Required fields** (`request_type`, `request_id`, `service`) must be present and non-empty
- On failure, raises `PhoenixGenApi.Errors.DecodeError` with a structured `:code`:
  - `:invalid_payload` — malformed data or oversized payload
  - `:missing_field` — one or more required fields are missing

The `use PhoenixGenApi` channel macro distinguishes these client errors from internal errors in its `rescue` block, returning `"Invalid request: ..."` for decode errors and `"Request processing failed"` for unexpected exceptions.

### Response

The gateway replies with a `%Response{}`:

| Field | Type | Description |
|---|---|---|
| `request_id` | `String.t()` | Matches the request |
| `result` | `any()` | Returned data |
| `success` | `boolean()` | Whether the call succeeded |
| `error` | `String.t() \| nil` | Error message on failure |
| `async` | `boolean()` | `true` if more messages will follow |
| `has_more` | `boolean()` | `true` for intermediate stream chunks |
| `can_retry` | `boolean()` | `true` if the client may retry |

---

## Configuration

### Gateway Configuration

In the gateway node's `config.exs`:

```elixir
config :phoenix_gen_api, :gen_api,
  pull_timeout: 5_000,
  pull_interval: 30_000,
  detail_error: false,
  service_configs: [
    %{
      service: "user_service",
      nodes: [:"app@host"],
      module: MyApp.GenApi.Supporter,
      function: :get_config,
      args: []
    }
  ]
```

| Option | Type | Default | Description |
|---|---|---|---|
| `pull_timeout` | `integer` | `5_000` | Timeout in ms for each pull RPC call |
| `pull_interval` | `integer` | `30_000` | Interval in ms between automatic pulls |
| `detail_error` | `boolean` | `false` | Include detailed error messages in responses |
| `service_configs` | `[map()]` | `[]` | List of service configurations for pull mode |
| `circuit_breaker_threshold` | `integer` | `10` | Pool-level consecutive failures before circuit opens (worker default: 5) |
| `circuit_breaker_cooldown` | `integer` | `60_000` | Cooldown in ms before circuit closes |

Each `service_config` map supports:

| Key | Type | Description |
|---|---|---|
| `service` | `String.t() \| atom()` | Service name (used as lookup key) |
| `nodes` | `[atom()] \| {m, f, a}` | Target nodes or MFA that resolves to node list |
| `module` | `module()` | Remote module implementing the config function |
| `function` | `atom()` | Function on the remote module |
| `args` | `list()` | Extra arguments passed to the config function |
| `version_module` | `module() \| nil` | Module for lightweight version check RPC |
| `version_function` | `atom() \| nil` | Function returning current config version |
| `version_args` | `list()` | Args for the version check function |

### Remote Node (Pull Mode)

Mark the node as a client so it doesn't start gateway-only services (RateLimiter, WorkerPool, ConfigDb, etc.):

```elixir
config :phoenix_gen_api, :client_mode, true
```

When `client_mode: true`, the application starts with an empty supervision tree and no ETS tables. This is the standard setting for service/worker nodes that push configs to the gateway.

**Pull startup behavior:** On application start, the `ConfigPuller` schedules an initial pull after 1 second. If the initial pull fails (service nodes unreachable), it logs a warning and retries with exponential backoff (up to 300s). The gateway starts even if service nodes are down — APIs register on first successful pull.

Define a supporter module that returns `FunConfig` lists:

```elixir
defmodule MyApp.GenApi.Supporter do
  alias PhoenixGenApi.Structs.FunConfig

  def get_config(_arg) do
    {:ok, my_fun_configs()}
  end

  def my_fun_configs do
    [
      %FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyApp.Api, :get_user, []},
        arg_types: %{"user_id" => :string},
        response_type: :sync,
        version: "1.0.0"
      }
    ]
  end
end
```

### Active Push (Remote → Gateway)

Remote nodes can push configs immediately on startup instead of waiting for a pull:

```elixir
alias PhoenixGenApi.ConfigPusher
alias PhoenixGenApi.Structs.{FunConfig, PushConfig}

fun_configs = [%FunConfig{ ... }]

push_config = %PushConfig{
  service: :user_service,
  nodes: [Node.self()],
  config_version: "1.0.0",
  fun_configs: fun_configs,
  # Optional: enable periodic pull after initial push
  module: MyApp.GenApi.Supporter,
  function: :get_config,
  args: []
}

ConfigPusher.push_on_startup(:"gateway@host", push_config)
```

Push is idempotent — if `config_version` matches, the push is skipped. Use `force: true` to override:

```elixir
ConfigPusher.push(:"gateway@host", push_config, force: true)
```

Verify a service's config version before pushing:

```elixir
case ConfigPusher.verify(:"gateway@host", :user_service, "1.0.0") do
  {:ok, :matched} -> :already_registered
  {:ok, :mismatch, _} -> ConfigPusher.push(:"gateway@host", push_config)
  {:error, :not_found} -> ConfigPusher.push(:"gateway@host", push_config)
end
```

Gateway-side API:

```elixir
# Receive a push (called via RPC from remote node)
{:ok, :accepted} = PhoenixGenApi.push_config(push_config)
{:ok, :skipped, :version_matches} = PhoenixGenApi.push_config(push_config)
{:ok, :accepted} = PhoenixGenApi.push_config(push_config, force: true)

# Verify a service's config version
{:ok, :matched} = PhoenixGenApi.verify_config("user_service", "1.0.0")
{:ok, :mismatch, "0.9.0"} = PhoenixGenApi.verify_config("user_service", "1.0.0")
{:error, :not_found} = PhoenixGenApi.verify_config("unknown", "1.0.0")

# Check pushed services (IEx helper)
PhoenixGenApi.pushed_services_status()
```

### Channel Integration

```elixir
defmodule MyAppWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"
end
```

Options:

| Option | Default | Description |
|---|---|---|
| `:event` | `"phoenix_gen_api"` | Channel event name for incoming requests and outgoing pushes |
| `:override_user_id` | `true` | Override `user_id` from `socket.assigns.user_id` (only if it's a non-empty string) |

The `use` macro injects these handlers:

- `handle_in(event, payload, socket)` — decodes the request via `Request.decode!/1`, executes it via `Executor.execute!`, replies to the client. Wraps errors in `try/rescue` to prevent channel crashes.
- `handle_info({:push, result}, socket)` — pushes sync results to the client
- `handle_info({:stream_response, result}, socket)` — pushes stream chunks
- `handle_info({:async_call, result}, socket)` — pushes async call results
- `handle_info({:relay_message, result}, socket)` — pushes relay messages to the client

It also derives `JSON.Encoder` for `Response` using the configured JSON library.

---

## Function Versioning

Run multiple versions of the same API side-by-side:

```elixir
# Version 1.0.0
%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "1.0.0",
  mfa: {MyApp.Users, :get_user_v1, []},
  arg_types: %{"id" => :string},
  response_type: :sync
}

# Version 2.0.0 — adds a "fields" argument
%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "2.0.0",
  mfa: {MyApp.Users, :get_user_v2, []},
  arg_types: %{"id" => :string, "fields" => :list_string},
  response_type: :sync
}
```

Clients request a specific version:

```json
{
  "service": "user_service",
  "request_type": "get_user",
  "request_id": "req_1",
  "version": "2.0.0",
  "args": { "id": "123", "fields": ["name", "email"] }
}
```

If no `version` is sent, `nil` is used. The value `"0.0.0"` is reserved as a sentinel meaning "no version specified" and cannot be explicitly registered as a version. Use `ConfigDb.get_latest/2` to resolve the highest enabled version.

### Managing Versions

```elixir
alias PhoenixGenApi.ConfigDb

# Get a specific version
{:ok, config} = ConfigDb.get("user_service", "get_user", "1.0.0")

# Get the latest enabled version
{:ok, latest} = ConfigDb.get_latest("user_service", "get_user")

# Disable a version (returns {:error, :disabled} when called)
:ok = ConfigDb.disable("user_service", "get_user", "1.0.0")

# Re-enable
:ok = ConfigDb.enable("user_service", "get_user", "1.0.0")

# Delete
:ok = ConfigDb.delete("user_service", "get_user", "1.0.0")

# List all functions with their versions
ConfigDb.get_all_functions()
```

**Behavior:**

- Disabled versions return `{:error, :disabled}`
- Non-existent versions return `{:error, :not_found}`
- `get_latest/2` returns the highest enabled version number (sorted semantically via `Version.compare/2`). Nil-version configs are always skipped.
- `get_fast/2` is an optimized lookup: returns the sole matching config directly, or the latest versioned config when multiple exist. Nil-version configs are returned when they are the sole match but excluded from "latest" resolution when versioned configs exist.
- Disabling one version does not affect others
- The value `"0.0.0"` is reserved — configs with this version are stored with a `nil` version key

---

## Rate Limiter

Sliding-window rate limiter backed by ETS. Uses a multi-instance architecture for high concurrency — instances are supervised under a `:one_for_one` supervisor and requests are routed via consistent hashing (`:erlang.phash2`) by default.

### Configuration

```elixir
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  fail_open: true,
  # Multi-instance sharding (default: number of online schedulers)
  instance_count: :auto,  # :auto or positive integer
  routing_strategy: :hash,  # :hash (consistent) or :random
  global_limits: [
    # 2 000 requests per minute per user
    %{key: :user_id, max_requests: 2000, window_ms: 60_000},
    # 10 000 requests per minute per device
    %{key: :device_id, max_requests: 10000, window_ms: 60_000}
  ],
  api_limits: [
    # Expensive operation: 10 requests per minute per user
    %{
      service: "data_service",
      request_type: "export_data",
      key: :user_id,
      max_requests: 10,
      window_ms: 60_000
    }
  ]
```

### Runtime API

```elixir
alias PhoenixGenApi.RateLimiter

# Check rate limit for a request
case RateLimiter.check_rate_limit(request) do
  :ok ->
    # Proceed
    Executor.execute!(request)

  {:error, :rate_limited, details} ->
    # Reject
    %{error: "Rate limit exceeded", retry_after: details.retry_after_ms}
end

# Check global/API-specific limits directly
RateLimiter.check_rate_limit("user_123", :global, :user_id)
RateLimiter.check_rate_limit("user_123", {"my_service", "my_api"}, :user_id)

# Dynamic configuration
RateLimiter.add_global_limit(%{key: :ip_address, max_requests: 5000, window_ms: 60_000})
RateLimiter.update_config(%{enabled: true, global_limits: [...], api_limits: [...]})
```

### Supported Keys

`:user_id`, `:device_id`, `:ip_address`, or any custom string key.

The rate limiter uses a sharded ETS architecture — multiple GenServer instances distribute the load. The routing strategy is `:erlang.phash2/1` by default (configurable via `routing_strategy`). ETS tables (`:rate_limiter_global` and `:rate_limiter_api`) are shared across all instances with `read_concurrency` and `write_concurrency` enabled.

### IEx Helpers

```elixir
PhoenixGenApi.rl_status("user_123")   # Rate limit status for a user
PhoenixGenApi.rl_global()             # Show global limits
PhoenixGenApi.rl_config()             # Show full rate limiter config
```

---

## Permission System

Four permission modes, configured per `FunConfig` via `check_permission`:

### 1. Disabled (`false`)

No check. Use for public endpoints.

```elixir
%FunConfig{request_type: "search", check_permission: false}
```

### 2. Any Authenticated (`:any_authenticated`)

Requires a non-nil `user_id`.

```elixir
%FunConfig{request_type: "get_profile", check_permission: :any_authenticated}
```

### 3. Argument-Based (`{:arg, arg_name}`)

The specified argument must match `user_id` — users can only access their own data.

```elixir
%FunConfig{request_type: "get_user_profile", check_permission: {:arg, "user_id"}}
# ✅ user_id: "user_123", args: %{"user_id" => "user_123"}
# ❌ user_id: "user_123", args: %{"user_id" => "user_999"}
```

### 4. Role-Based (`{:role, allowed_roles}`)

User must have at least one of the specified roles.

```elixir
%FunConfig{request_type: "delete_user", check_permission: {:role, ["admin", "moderator"]}}
# ✅ user_roles: ["admin"]
# ❌ user_roles: ["user"]
```

**Notes:**

- Permission checks run *before* argument validation and function execution
- All permission failures are logged for auditing
- Missing arguments result in denial

---

## Relay Messages

Group-based message relaying: a user sends a message to a group, and all members (including the sender) receive it through their Phoenix Channel.

### Group Types

| Type | Join | Accept | Mute/Unmute | Who can send |
|---|---|---|---|---|
| `:public` | Immediate `:active` | N/A | ❌ | Any `:active` member |
| `:private` | `:pending` | Any `:active` member | ❌ | Any `:active` member |
| `:strict_private` | `:pending` | Only `:admin` | Admin only | `:active` (not muted) |

Muted members in `:strict_private` groups can **receive** messages but cannot **send** them.

### Architecture

- **ETS table** (`:phoenix_gen_api_relay_groups`) stores group metadata: type, members, roles, status.
- **Registry** (`PhoenixGenApi.RelayRegistry`) with `:duplicate` keys maps `group_id` to `{user_id, channel_pid}` for dispatching.
- **Process monitoring** — `RelayServer` monitors channel processes on join. When a channel dies, membership is auto-cleaned.

### Example FunConfig Setup

```elixir
# Create a group (one-time setup, e.g. in an admin API)
PhoenixGenApi.Relay.create_group("room_1", :public, "admin_user", channel_pid)

# Join a group
PhoenixGenApi.Relay.join_group("room_1", "user_2", user2_channel_pid)

# Accept a pending member (private/strict_private)
PhoenixGenApi.Relay.accept_member("room_1", "admin_user", "user_2")

# Mute a member (strict_private only)
PhoenixGenApi.Relay.mute_member("room_1", "admin_user", "user_2")

# Send a relay message (configured as FunConfig, called via WebSocket)
%FunConfig{
  request_type: "relay_msg",
  service: "chat_service",
  nodes: :local,
  mfa: {PhoenixGenApi.Relay, :handle_relay, []},
  arg_types: %{"group_id" => :string, "message" => :string},
  arg_orders: ["group_id", "message"],
  check_permission: :any_authenticated,
  response_type: :sync
}
```

### Client → Server → All Members Flow

```
Client A                    Gateway (Phoenix Channel)           Client B
  │  WebSocket: relay_msg                                      │
  │  {group_id, message}                                       │
  │──────────────────────────►│                                 │
  │                            │ handle_in()                     │
  │                            │  └─ Executor.execute!(request)  │
  │                            │     └─ Relay.handle_relay()     │
  │                            │        ├─ ETS: validate member  │
  │                            │        ├─ Registry: dispatch     │
  │                            │        └─ send(pid, {:relay_message, response})
  │                            │                                 │
  │                            │ handle_info({:relay_message})  │
  │                            │  └─ push(socket, result)───────►│
  │◄───────────────────────────│                                 │
  │  {status: "relayed",       │                                 │
  │   recipients_count: 2}     │                                 │
```

### Client WebSocket Payload

```json
{
  "service": "chat_service",
  "request_type": "relay_msg",
  "request_id": "req_123",
  "args": {
    "group_id": "room_1",
    "message": "Hello everyone!"
  }
}
```

### Client Receives (all members)

```json
{
  "request_id": "req_123",
  "success": true,
  "result": {
    "group_id": "room_1",
    "from_user_id": "user_1",
    "message": "Hello everyone!",
    "timestamp": "2025-01-15T10:30:00Z"
  }
}
```

### Direct API (outside WebSocket)

You can also manage groups programmatically:

```elixir
# Create
:ok = PhoenixGenApi.Relay.create_group("room_1", :public, "admin", channel_pid)

# Join
{:ok, :active} = PhoenixGenApi.Relay.join_group("room_1", "user_2", pid)

# Leave
:ok = PhoenixGenApi.Relay.leave_group("room_1", "user_2")

# Accept (private/strict_private)
:ok = PhoenixGenApi.Relay.accept_member("room_1", "admin", "user_2")

# Mute / Unmute (strict_private only)
:ok = PhoenixGenApi.Relay.mute_member("room_1", "admin", "user_2")
:ok = PhoenixGenApi.Relay.unmute_member("room_1", "admin", "user_2")

# Inspect
{:ok, info} = PhoenixGenApi.Relay.get_group_info("room_1")
```

---

## Retry

Configure retry behavior when execution fails:

| Value | Meaning |
|---|---|
| `nil` | No retry (default) |
| `3` | Equivalent to `{:all_nodes, 3}` |
| `{:same_node, 2}` | Retry on the originally selected node(s) |
| `{:all_nodes, 3}` | Retry across all available nodes |

```elixir
%FunConfig{
  request_type: "get_data",
  service: "my_service",
  nodes: [:"node1@host", :"node2@host", :"node3@host"],
  mfa: {MyApp.Api, :get_data, []},
  retry: {:all_nodes, 3}  # Retry up to 3 times across all nodes
}
```

For `nodes: :local`, both `:same_node` and `:all_nodes` retry locally.

Retry attempts emit telemetry at `[:phoenix_gen_api, :executor, :retry]` with metadata including `mode` (`:same_node` or `:all_nodes`), `type` (`:local` or `:remote`), and the current `attempt` number in measurements.

When all retry attempts are exhausted, a `[:phoenix_gen_api, :executor, :retry, :exhausted]` event is emitted with the original retry configuration and the final error. This event is emitted for both local and remote retries.

---

## Telemetry

31 events across 5 categories:

| Category | Events | Description |
|---|---|---|
| Executor | 4 | Request lifecycle (`start`/`stop`/`exception`) and retry |
| Rate Limiter | 4 | Check, exceeded, reset, cleanup |
| Hooks | 6 | Before/after hook `start`/`stop`/`exception` |
| Worker Pool | 6 | Task `start`/`stop`/`exception`/`rejected`, circuit breaker `open`/`close` |
| Config Cache | 9 | Pull/push, add, batch_add, delete, clear, disable, enable |

> **Note**: The `[:phoenix_gen_api, :worker_pool, :task, :rejected]` event is emitted when a task is rejected due to the circuit breaker being open.

### Quick Start

```elixir
# Attach to all events
PhoenixGenApi.Telemetry.attach_all("my-app", fn event, measurements, metadata, _config ->
  Logger.info("[Telemetry] #{inspect(event)} #{inspect(measurements)}")
end)

# Attach to executor events only
PhoenixGenApi.Telemetry.attach_executor("my-app-exec", fn event, measurements, metadata, _config ->
  case event do
    [:phoenix_gen_api, :executor, :request, :stop] ->
      Logger.info("Request #{metadata.request_id} completed in #{measurements.duration_us}µs")
    _ ->
      :ok
  end
end)

# Built-in debug logger
PhoenixGenApi.Telemetry.attach_default_logger()

# List all available events
PhoenixGenApi.Telemetry.list_events()

# Detach when done
PhoenixGenApi.Telemetry.detach_all("my-app")
```

You can also use the convenience functions on the main module:

```elixir
PhoenixGenApi.attach_telemetry("my-app", &MyHandler.handle_event/4)
PhoenixGenApi.detach_telemetry("my-app")
```

These attach to both executor and rate limiter events simultaneously.

### Integration with Telemetry.Metrics

```elixir
defmodule MyApp.Metrics do
  def metrics do
    [
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.executor.request.duration_us",
        event_name: [:phoenix_gen_api, :executor, :request, :stop],
        measurement: :duration_us,
        tags: [:service, :request_type, :success]
      ),
      Telemetry.Metrics.counter(
        "phoenix_gen_api.executor.exceptions.count",
        event_name: [:phoenix_gen_api, :executor, :request, :exception],
        tags: [:service, :request_type]
      ),
      Telemetry.Metrics.counter(
        "phoenix_gen_api.rate_limiter.exceeded.count",
        event_name: [:phoenix_gen_api, :rate_limiter, :exceeded],
        tags: [:key, :scope]
      )
    ]
  end
end
```

📖 For the complete event reference, integration patterns, and best practices, see the [Telemetry Guide](guides/telemetry.md).

---

## IEx Helpers

```elixir
PhoenixGenApi.rl_status("user_123")     # Rate limit status
PhoenixGenApi.rl_global()               # Global rate limits
PhoenixGenApi.rl_global(limits)         # Set global rate limits
PhoenixGenApi.rl_config()               # Rate limiter config
PhoenixGenApi.cache_status()            # Config cache status
PhoenixGenApi.pool_status()             # Worker pool status
PhoenixGenApi.pushed_services_status()  # Pushed services status
```

---

## Related Packages

All packages in the PhoenixGenApi ecosystem:

| Package | Description |
|---|---|
| [PhoenixGenApi](https://hex.pm/packages/phoenix_gen_api) | Core library — dynamic API gateway over Phoenix Channels |
| [EasyRpc](https://hex.pm/packages/easy_rpc) | Wrap RPC calls from remote nodes so they can be used like local functions. Simplifies exposing remote functions as local APIs |
| [ClusterHelper](https://hex.pm/packages/cluster_helper) | Dynamic cluster node discovery. Map nodes to roles or IDs and select nodes by role/ID |
| [ToonEx](https://hex.pm/packages/toon_ex) | TOON encoder/decoder for Elixir — a compact binary protocol for Phoenix Channels. TOON-to-JSON converter for efficient WebSocket transport |
| [AshPhoenixGenApi](https://hex.pm/packages/ash_phoenix_gen_api) | Ash extension that auto-generates `FunConfig` definitions from Ash resources |

## AI Agent Support

Update usage rules from dependencies:

```bash
mix usage_rules.sync AGENTS.md --all --link-to-folder deps --inline usage_rules:all
```

Start the Tidewave MCP server:

```bash
mix tidewave
```

Connect at `http://localhost:4114/tidewave/mcp`. See [Tidewave](https://hexdocs.pm/tidewave/) for details.
