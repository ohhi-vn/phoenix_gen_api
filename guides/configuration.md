# Configuration Reference

Complete reference for all application-level configuration options.

## Table of Contents

1. [Gateway Configuration](#gateway-configuration)
2. [Service Config (Pull Mode)](#service-config-pull-mode)
3. [Rate Limiter](#rate-limiter)
4. [Worker Pool](#worker-pool)
5. [Security](#security)
6. [Channel Integration](#channel-integration)
7. [Function Versioning](#function-versioning)
8. [ConfigDb Runtime API](#configdb-runtime-api)

---

## Gateway Configuration

In the gateway node's `config.exs`:

```elixir
config :phoenix_gen_api, :gen_api,
  pull_timeout: 5_000,
  pull_interval: 30_000,
  detail_error: false,
  service_configs: [...]
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pull_timeout` | `integer` | `5_000` | Timeout in ms for each pull RPC call |
| `pull_interval` | `integer` | `30_000` | Interval in ms between automatic pulls |
| `detail_error` | `boolean` | `false` | Include detailed error messages in responses |
| `service_configs` | `[map()]` | `[]` | List of service configurations for pull mode |

### Service Config (each entry)

| Key | Type | Description |
|-----|------|-------------|
| `service` | `String.t() \| atom()` | Service name (used as lookup key) |
| `nodes` | `[atom()] \| {m, f, a}` | Target nodes or MFA that resolves to node list |
| `module` | `module()` | Remote module implementing the config function |
| `function` | `atom()` | Function on the remote module |
| `args` | `list()` | Extra arguments passed to the config function |
| `version_module` | `module() \| nil` | Module for lightweight version check RPC |
| `version_function` | `atom() \| nil` | Function returning current config version |
| `version_args` | `list()` | Args for the version check function |

### Version-based skip

When `version_module` and `version_function` are configured, the puller first makes a lightweight RPC to check if the version changed. If it matches the stored version, the full config pull is skipped entirely — saving network bandwidth.

```elixir
service_configs: [%{
  service: "user_service",
  nodes: [:"app@host"],
  module: MyApp.GenApi.Supporter,
  function: :get_config,
  args: [],
  version_module: MyApp.GenApi.Supporter,
  version_function: :get_config_version,
  version_args: []
}]
```

---

## Remote Node (Pull Mode)

Mark the node as a client so it doesn't start gateway-only services:

```elixir
config :phoenix_gen_api, :client_mode, true
```

When `client_mode: true`, the application starts with an empty supervision tree and no ETS tables. This is the standard setting for service/worker nodes.

### Pull startup behavior

On application start, the `ConfigPuller` schedules an initial pull after 1 second. If the initial pull fails (service nodes unreachable), it logs a warning and retries with exponential backoff (up to 300s). The gateway starts even if service nodes are down — APIs register on first successful pull.

### Supporter module

Define a supporter module that returns `FunConfig` lists:

```elixir
defmodule MyApp.GenApi.Supporter do
  alias PhoenixGenApi.Structs.FunConfig

  def get_config(_arg) do
    {:ok, [
      %FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: [Node.self()],
        mfa: {MyApp.Api, :get_user, []},
        arg_types: %{"user_id" => :string},
        response_type: :sync,
        version: "1.0.0"
      }
    ]}
  end

  # Optional: version check function
  def get_config_version, do: "1.0.0"
end
```

### Push mode (service → gateway)

Remote nodes can push configs immediately on startup:

```elixir
alias PhoenixGenApi.ConfigPusher

push_config = ConfigPusher.from_service_config(
  :user_service,
  [Node.self()],
  fun_configs,
  config_version: "1.0.0",
  module: MyApp.GenApi.Supporter,
  function: :get_config
)

ConfigPusher.push_on_startup(:"gateway@host", push_config)
```

Push is idempotent — if `config_version` matches, the push is skipped. Use `force: true` to override.

Verify before pushing:

```elixir
case ConfigPusher.verify(:"gateway@host", :user_service, "1.0.0") do
  {:ok, :matched} -> :already_registered
  {:ok, :mismatch, _} -> ConfigPusher.push(:"gateway@host", push_config)
  {:error, :not_found} -> ConfigPusher.push(:"gateway@host", push_config)
end
```

Gateway-side API:

```elixir
{:ok, :accepted} = PhoenixGenApi.push_config(push_config)
{:ok, :accepted} = PhoenixGenApi.push_config(push_config, force: true)
{:ok, :matched} = PhoenixGenApi.verify_config("user_service", "1.0.0")
PhoenixGenApi.pushed_services_status()
```

---

## Rate Limiter

Sliding-window rate limiter backed by ETS with multi-instance sharding.

```elixir
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  fail_open: true,
  instance_count: :auto,
  routing_strategy: :hash,
  global_limits: [
    %{key: :user_id, max_requests: 2000, window_ms: 60_000},
    %{key: :device_id, max_requests: 10000, window_ms: 60_000}
  ],
  api_limits: [
    %{
      service: "data_service",
      request_type: "export_data",
      key: :user_id,
      max_requests: 10,
      window_ms: 60_000
    }
  ]
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | `boolean` | `true` | Enable/disable rate limiting |
| `fail_open` | `boolean` | `true` | Allow requests through if rate limiter errors |
| `instance_count` | `:auto \| integer` | `:auto` | Number of rate limiter instances |
| `routing_strategy` | `:hash \| :random` | `:hash` | Instance routing strategy |
| `global_limits` | `[map()]` | `[]` | Limits applied to all requests |
| `api_limits` | `[map()]` | `[]` | Limits applied to specific service/request_type pairs |

### Limit schema

| Key | Type | Description |
|-----|------|-------------|
| `key` | `:user_id \| :device_id \| :ip_address \| atom()` | Request field to key on |
| `max_requests` | `pos_integer` | Maximum requests within the window |
| `window_ms` | `pos_integer` | Window size in milliseconds |
| `service` | `String.t() \| atom()` | (api_limits only) Service name |
| `request_type` | `String.t()` | (api_limits only) Request type |

### Runtime API

```elixir
alias PhoenixGenApi.RateLimiter

# Check a request
RateLimiter.check_rate_limit(request)

# Check a specific limit directly
RateLimiter.check_rate_limit("user_123", :global, :user_id)
RateLimiter.check_rate_limit("user_123", {"svc", "api"}, :user_id)

# Dynamic configuration
RateLimiter.add_global_limit(%{key: :ip, max_requests: 5000, window_ms: 60_000})
RateLimiter.remove_global_limit(:ip)
RateLimiter.reset_rate_limit("user_123", :global, :user_id)
RateLimiter.get_rate_limit_status("user_123", :global, :user_id)
RateLimiter.update_config(%{enabled: true, global_limits: [...], api_limits: [...]})
```

---

## Worker Pool

```elixir
config :phoenix_gen_api, :worker_pool,
  async_pool_size: 1000,
  stream_pool_size: 500,
  max_queue_size: 10_000,
  circuit_breaker_threshold: 10,
  circuit_breaker_cooldown: 60_000
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `async_pool_size` | `integer` | `1000` | Number of workers in the async pool |
| `stream_pool_size` | `integer` | `500` | Number of workers in the stream pool |
| `max_queue_size` | `integer` | `10_000` | Maximum queued tasks per pool |
| `circuit_breaker_threshold` | `integer` | `10` | Pool-level consecutive failures before circuit opens |
| `circuit_breaker_cooldown` | `integer` | `60_000` | Cooldown in ms before circuit closes |

Worker-level circuit breaker threshold defaults to 5.

### Pool status

```elixir
PhoenixGenApi.pool_status()
# Returns: %{idle_workers: 950, busy_workers: 50, queued_tasks: 0, circuit_open: false, ...}
```

---

## Security

```elixir
config :phoenix_gen_api,
  admin_actions: [:push_config, :update_rate_limit_config],
  push_token: "my-secret-token",
  mfa_allowlist: [
    MyApp.UserService,
    {MyApp.OrderService, :create_order}
  ]
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `admin_actions` | `[atom()]` | `[]` | Allowed admin operations (fail-closed) |
| `push_token` | `String.t() \| nil` | `nil` | Token for authenticating push requests |
| `mfa_allowlist` | `[module() \| tuple]` | `nil` | Allowed `{module, function}` pairs |

### Admin actions

| Action | Description |
|--------|-------------|
| `:push_config` | Allow receiving config pushes from remote nodes |
| `:update_rate_limit_config` | Allow runtime rate limit config changes |
| `:change_detail_error` | Allow toggling detailed error messages |

### MFA allowlist

When configured, only listed `{module, function}` pairs can be registered as function configs. Module-level entries allow all functions in that module. The following modules are **always blocked** unless explicitly allowed: `:os`, `:file`, `:code`, `:erlang`, `:net`, `:rpc`, `:global`, `:inet`.

### Payload size limit

```elixir
config :phoenix_gen_api, :request, max_payload_bytes: 1_000_000
```

Default: 1MB. Checked **before** deserialization to prevent memory exhaustion.

---

## Channel Integration

```elixir
defmodule MyAppWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"
end
```

| Option | Default | Description |
|--------|---------|-------------|
| `:event` | `"phoenix_gen_api"` | Channel event name for requests and pushes |
| `:override_user_id` | `true` | Override `user_id` from `socket.assigns.user_id` |

### Injected handlers

`use PhoenixGenApi` automatically injects:

- `handle_in(event, payload, socket)` — decodes and executes requests
- `handle_info({:push, result}, socket)` — pushes sync results
- `handle_info({:stream_response, result}, socket)` — pushes stream chunks
- `handle_info({:async_call, result}, socket)` — pushes async results
- `handle_info({:relay_message, result}, socket)` — pushes relay messages

---

## Function Versioning

Multiple versions of the same API can coexist:

```elixir
# Register v1
ConfigDb.add(%FunConfig{request_type: "get_user", version: "1.0.0", ...})

# Register v2
ConfigDb.add(%FunConfig{request_type: "get_user", version: "2.0.0", ...})
```

Clients request a specific version via the `version` field. If no version is sent, the config with `nil` version is used.

The value `"0.0.0"` is reserved as a sentinel and cannot be explicitly registered.

### Version management

```elixir
alias PhoenixGenApi.ConfigDb

ConfigDb.get("user_service", "get_user", "1.0.0")     # Specific version
ConfigDb.get_latest("user_service", "get_user")        # Highest enabled version
ConfigDb.disable("user_service", "get_user", "1.0.0")  # Soft-delete
ConfigDb.enable("user_service", "get_user", "1.0.0")   # Re-enable
ConfigDb.delete("user_service", "get_user", "1.0.0")   # Permanent delete
ConfigDb.get_all_functions()                            # List all
```

---

## ConfigDb Runtime API

```elixir
alias PhoenixGenApi.ConfigDb

# Add/update
ConfigDb.add(%FunConfig{...})
ConfigDb.batch_add([%FunConfig{...}, %FunConfig{...}])
ConfigDb.update(%FunConfig{...})

# Lookup
ConfigDb.get("user_service", "get_user", "1.0.0")
ConfigDb.get_fast("user_service", "get_user")
ConfigDb.get_latest("user_service", "get_user")

# Version management
ConfigDb.disable("user_service", "get_user", "1.0.0")
ConfigDb.enable("user_service", "get_user", "1.0.0")
ConfigDb.delete("user_service", "get_user", "1.0.0")

# Listing
ConfigDb.get_all_functions()
ConfigDb.get_functions_from_services(["user_service"])
ConfigDb.get_all_services()
ConfigDb.count()

# Cache management
ConfigDb.clear()

# IEx helper
PhoenixGenApi.cache_status()
```

---

## What's Next

- **[FunConfig Reference](./fun_config.md)** — Field-by-field reference for the central configuration struct.
- **[Step-by-Step Guide](./step_by_step_guide.md)** — Code examples for each configuration option.
- **[Architecture](./architecture.md)** — How configuration flows through the system.
- **[Rate Limiter](../README.md#rate-limiter)** — Feature overview in the README.
