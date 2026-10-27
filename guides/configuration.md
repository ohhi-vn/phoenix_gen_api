# Configuration Reference

Complete reference for all application-level configuration options.

## Table of Contents

1. [Gateway Configuration](#gateway-configuration)
2. [Service Config (Pull Mode)](#service-config-pull-mode)
3. [Rate Limiter](#rate-limiter)
4. [Worker Pool](#worker-pool)
5. [Security](#security)
6. [Channel Integration](#channel-integration)
7. [ConfigDb Runtime API](#configdb-runtime-api)
8. [Logging](#logging)

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

### Push authentication and provenance

```elixir
config :phoenix_gen_api,
  # Require a token on every push (nil = token not required).
  push_token: "shared-secret",
  # When admin_actions is configured, :push_config must be allowed to push.
  admin_actions: [:push_config],
  # Require the pushing node to be listed in the pushed config's nodes.
  config_source_binding: true,
  # Optional service -> owner node map; pushes must come from the owner.
  service_owners: %{"billing" => :"billing@host"},
  # Optional allowlist for nodes the puller may target.
  pull_node_allowlist: [:"service1@host", :"service2@host"],
  # Gate puller registration/forced pulls behind :push_config.
  protect_config_puller: true
```

A rejected push returns `{:error, reason}` where `reason` is `:invalid_push_token`,
`:admin_action_denied`, `:source_not_allowed`, `:version_downgrade`, or a validation
error. With no token and no `admin_actions` configured, push behaviour is unchanged
(unauthenticated, as before).

### Versioning and retention

- `config_version` is compared when both versions parse: an older push is accepted with a
  warning by default and rejected when `reject_config_downgrades: true` (unless forced).
- Client-selected versions are honoured by default. Set `allow_client_version: false` to
  always resolve the latest configuration.
- `max_configs_per_service` bounds stored versions per service/request type; the oldest
  versions are evicted first.
- Failed-configuration records expire after 24 hours and are swept hourly
  (`config_failed_cleanup_interval`).

### All-or-nothing validation

Every write path — `ConfigDb.add/1`, `ConfigDb.update/1`, `ConfigDb.batch_add/1`,
`ConfigReceiver.push/1`, and puller registration — validates the same rules, including
every invocable MFA (endpoint, `nodes`, hooks, `permission_callback`, `result_encoder`).
A rejected write leaves the previously stored configuration in place.

### Pull failure reporting

A pull is successful only when every service either stored configuration or was skipped
because its version matched. Partial failures are reported per service with a reason and
emit `[:phoenix_gen_api, :config, :pull, :error]`; a pull that stored nothing is a
failure, not a success. A missing `ConfigDb` table is reported as `{:error, :unavailable}`
and produces a retryable "Service temporarily unavailable" response, distinct from an
unknown function.

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
| `routing_strategy` | `:hash \| :random` | `:hash` | Instance routing strategy (`:random` is deprecated; keys are always hashed for correctness) |
| `global_limits` | `[map()]` | `[]` | Limits applied to all requests |
| `api_limits` | `[map()]` | `[]` | Limits applied to specific service/request_type pairs |
| `timeout` | `pos_integer` | `1000` | Per-check call timeout (ms) |
| `cleanup_interval` | `pos_integer` | `60000` | Expired-row sweep interval (ms) |
| `ip_address_source` | `atom()` | `nil` | Request field that carries the client IP for `:ip_address` limits |
| `max_rate_limit_keys` | `pos_integer` | `nil` | Cap on distinct limiter keys; excess keys share an overflow bucket |
| `max_rate_limit_key_bytes` | `pos_integer` | `nil` | Keys longer than this are hashed before storage |

### Limit schema

| Key | Type | Description |
|-----|------|-------------|
| `key` | `:user_id \| :device_id \| :ip_address \| String.t()` | Request field to key on; a string reads that key from `request.args` |
| `max_requests` | `pos_integer` | Maximum requests within the window |
| `window_ms` | `pos_integer` | Window size in milliseconds |
| `service` | `String.t() \| atom()` | (api_limits only) Service name |
| `request_type` | `String.t()` | (api_limits only) Request type |

### Behaviour notes

- **No limits means no cost.** With `global_limits`/`api_limits` empty (or the limiter
  disabled), requests skip the limiter process entirely. Runtime changes through
  `set_global_limits/1`, `add_global_limit/1`, `remove_global_limit/1`, or
  `update_config/1` take effect immediately without a restart.
- **Fail mode covers every failure.** Timeouts, process exits, missing instances, and
  exceptions all honour `fail_open`; the failure class and reason are attached to the
  `[:phoenix_gen_api, :rate_limiter, :check]` telemetry event.
- **Keys are hashed to one instance.** `:random` routing cannot keep a key's counters
  consistent, so it is accepted but ignored and logged as deprecated.
- **Memory is bounded.** Each key stores at most `max_requests` timestamps; cleanup sweeps
  expired rows in the background at `cleanup_interval`. Set `max_rate_limit_keys` to cap
  cardinality from client-controlled keys, and `max_rate_limit_key_bytes` to bound key
  size.
- **`:ip_address` needs a source.** Requests do not carry an IP by default. Configure
  `ip_address_source` (for example `:device_id`, or a field your transport adds) or the
  limit is skipped and a warning is logged at configuration time.
- **Administration is gated.** When `:admin_actions` is configured, replacing, adding, or
  removing limits, resetting counters, and clearing state all require
  `:update_rate_limit_config`, including direct instance calls.

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

`busy_workers` includes workers paused by an open circuit, `total_tasks_failed` counts
failed/crashed/timed-out tasks, and dead workers are excluded while they are replaced.
Streams run on `:stream_pool` capacity, so a long stream does not occupy an async slot.
See "Worker Pools & Circuit Breakers" in the architecture guide for the delivery
guarantees.

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
| `admin_actions` | `[atom()]` | `[]` | Allowed admin operations (fail-closed once configured) |
| `push_token` | `String.t() \| nil` | `nil` | Token for authenticating push requests |
| `mfa_allowlist` | `[module() \| tuple]` | `nil` | Allowed `{module, function}` pairs |

### Admin actions

| Action | Description |
|--------|-------------|
| `:push_config` | Allow receiving config pushes from remote nodes |
| `:update_rate_limit_config` | Allow runtime rate limit config changes (and puller administration when `protect_config_puller` is on) |
| `:change_detail_error` | Allow toggling detailed error messages |
| `:enable_tracing` | Allow enabling tracing / adding traced targets |
| `:disable_tracing` | Allow disabling tracing / removing traced targets |

Once `admin_actions` is set, an action not in the list is denied, including when invoked
directly on the owning process. When `admin_actions` is unset, existing behaviour is
preserved. The push token is compared using a fixed-length digest, so timing does not
reveal the configured secret's length.

### MFA allowlist

When configured, only listed `{module, function}` pairs can be registered as function
configs. Module-level entries allow all functions in that module, and matching is exact —
a prefix or lookalike module is not accepted. The following modules are **always blocked**
unless explicitly allowed: `:os`, `:file`, `:code`, `:erlang`, `:net`, `:rpc`, `:global`,
`:inet`, plus `Code`, `File`, `System`, `Node`, `IO`, `:ets`, `:application`,
`:persistent_term`, `:logger`, `:gen_server`, `:supervisor`, and `:process`.

Every MFA a config can invoke is checked — endpoint, `nodes`, hooks,
`permission_callback`, and `result_encoder` — at registration time, not on first use.

### Identity and atom safety

- `use PhoenixGenApi, require_authenticated_roles: true` ignores payload `user_roles` and
  reads roles from `socket.assigns`.
- `use PhoenixGenApi, reject_unverified_user_id: true` treats a payload `user_id` as
  absent when the socket has no verified identifier.
- Both default to `false` (today's behaviour) so upgrades are non-breaking.
- No request field, configuration value, or administrative input creates atoms; unknown
  names are matched against existing atoms only.

### Internal tables

`protect_internal_tables: true` makes the library's named ETS tables `:protected` so only
their owning process can write. ConfigDb writes are routed through its GenServer,
failed-config records through the ConfigFailed owner, relay state through RelayServer, and
the rate limiter pins all checks to the owning instance (sharding is disabled in this
mode).

### Recommended production set

```elixir
config :phoenix_gen_api,
  admin_actions: [:push_config, :update_rate_limit_config, :enable_tracing, :disable_tracing],
  push_token: System.fetch_env!("PGA_PUSH_TOKEN"),
  mfa_allowlist: [MyApp.GenApi.Endpoints],
  config_source_binding: true,
  reject_config_downgrades: true,
  protect_internal_tables: true,
  max_configs_per_service: 20,
  max_rate_limit_keys: 100_000,
  max_rate_limit_key_bytes: 256
```

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

Function versioning (multiple `version` values per endpoint, the `"0.0.0"` sentinel, and runtime version management) is covered in the [FunConfig Reference](./fun_config.md#function-versioning).

---

## Logging

PhoenixGenApi emits `[Module] event=<name>` log lines with inline context such as
`request_id`, `request_type`, `service`, `user_id`, `node`, `config_version`, and `version`. Context is
also installed as Logger metadata (`request_id`, `request_type`, `service`, `user_id`,
`node`) for the duration of a request, so formatters and structured backends can use it.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `log_verbose_payloads` | `boolean` | `false` | Include full request payloads, argument values, and results in debug logs. Leave disabled in production. |

```elixir
# config/config.exs
config :phoenix_gen_api, log_verbose_payloads: false
```

With verbose logging disabled (the default), debug lines record request identity plus a
payload summary (`size`, top-level `keys`) and never the payload contents. Push tokens
are always redacted regardless of this setting.

See [Diagnostics → Logging context](./diagnostics.md#logging-context) for the key
vocabulary and a Logger formatter snippet.

---

## What's Next

- **[FunConfig Reference](./fun_config.md)** — Field-by-field reference for the central configuration struct.
- **[Getting Started](./getting_started.md)** — The full walkthrough from a single node to a cluster.
- **[Architecture](./architecture.md)** — How configuration flows through the system.
- **[Rate Limiter](../README.md#rate-limiter)** — Feature overview in the README.
