[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/phoenix_gen_api)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_gen_api.svg?style=flat&color=blue)](https://hex.pm/packages/phoenix_gen_api)

# PhoenixGenApi

Build dynamic API gateways on top of Phoenix Channels. Register APIs at runtime from any node in the cluster — no restarts, no redeploys.

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
- **Retry** — Configurable retry on the same node or across all nodes
- **Hooks** — `before_execute` / `after_execute` callbacks for cross-cutting concerns
- **Telemetry** — 28 events across 5 categories for observability

## Installation

Requires Elixir ~> 1.18 and OTP ~> 27.

```elixir
def deps do
  [
    {:phoenix_gen_api, "~> 2.10"}
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
| `request_info` | `boolean()` | Pass the full `%Request{}` as first arg to the MFA |
| `version` | `String.t()` | API version (default `"0.0.0"`) |
| `disabled` | `boolean()` | Disable this version without removing it |
| `retry` | `nil \| number \| {:same_node, n} \| {:all_nodes, n}` | Retry configuration |
| `before_execute` | `{m, f} \| {m, f, a} \| nil` | Hook called before execution |
| `after_execute` | `{m, f} \| {m, f, a} \| nil` | Hook called after execution |

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
| `version` | `String.t() \| nil` | Requested API version |

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

### Remote Node (Pull Mode)

Mark the node as a client so it can push configs:

```elixir
config :phoenix_gen_api, :client_mode, true
```

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
| `:event` | `"phoenix_gen_api"` | Channel event name |
| `:override_user_id` | `true` | Override `user_id` from `socket.assigns.user_id` |

The `use` macro injects these handlers:

- `handle_in(event, payload, socket)` — decodes the request, executes it, replies
- `handle_info({:push, result}, socket)` — pushes async results to the client
- `handle_info({:stream_response, result}, socket)` — pushes stream chunks
- `handle_info({:async_call, result}, socket)` — pushes async call results

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

If no `version` is sent, `"0.0.0"` is used.

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
- `get_latest/2` returns the highest enabled version number
- Disabling one version does not affect others

---

## Rate Limiter

Sliding-window rate limiter backed by ETS.

### Configuration

```elixir
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  fail_open: true,
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

Retry attempts emit telemetry at `[:phoenix_gen_api, :executor, :retry]`.

---

## Telemetry

28 events across 5 categories:

| Category | Events | Description |
|---|---|---|
| Executor | 4 | Request lifecycle (`start`/`stop`/`exception`) and retry |
| Rate Limiter | 4 | Check, exceeded, reset, cleanup |
| Hooks | 6 | Before/after hook `start`/`stop`/`exception` |
| Worker Pool | 5 | Task `start`/`stop`/`exception`, circuit breaker `open`/`close` |
| Config Cache | 9 | Pull/push, add, batch_add, delete, clear, disable, enable |

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
```

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

- [EasyRpc](https://hex.pm/packages/easy_rpc) — Simplified RPC calls in an Elixir cluster
- [ClusterHelper](https://hex.pm/packages/cluster_helper) — Cluster node discovery and management
- [AshPhoenixGenApi](https://hex.pm/packages/ash_phoenix_gen_api) — Auto-generate FunConfig from Ash resources

## Planned Features

- ~~Worker pools for resource limiting~~ ✅
- ~~Function versioning with enable/disable~~ ✅
- ~~Sliding-window rate limiter~~ ✅
- ~~Active push from remote node to gateway~~ ✅
- Sticky node affinity

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