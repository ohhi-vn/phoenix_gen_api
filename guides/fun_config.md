# FunConfig Reference

`FunConfig` is the central configuration struct. Each `FunConfig` maps one `{service, request_type}` pair to one function call.

> **Important:** several fields have **no default** — `choose_node_mode`, `response_type`, and (when `arg_types` is set) `arg_orders` must be set explicitly or validation fails. See the Schema table.

## Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `request_type` | `String.t()` | **required** | API endpoint name (e.g. `"get_user"`) |
| `service` | `atom \| String.t()` | **required** | Service group name (e.g. `"user_service"`) |
| `nodes` | `[atom] \| {m,f,a} \| :local` | **required** | Target nodes, a dynamic resolver MFA, or `:local` for same-node execution |
| `choose_node_mode` | `atom \| tuple` | **required** | Node selection strategy (see below) |
| `timeout` | `integer \| :infinity` | **required** | Execution timeout in ms (100–300_000 or `:infinity`) |
| `mfa` | `{module, function, args}` | **required** | The function to call |
| `arg_types` | `map() \| nil` | `nil` | Argument type declarations for validation |
| `arg_orders` | `[String.t()] \| :map` | **required if `arg_types` set** | Argument ordering (or `:map` to pass a map) |
| `response_type` | `atom` | **required** | `:sync` \| `:async` \| `:stream` \| `:none` |
| `check_permission` | `atom \| tuple` | `false` | Permission mode (see below) |
| `permission_callback` | `{m,f,a} \| nil` | `nil` | Custom permission check MFA |
| `version` | `String.t() \| nil` | `nil` | API version. `"0.0.0"` is reserved as a sentinel |
| `disabled` | `boolean` | `false` | Soft-delete flag |
| `retry` | `nil \| number \| tuple` | `nil` | Retry configuration (see below) |
| `before_execute` | `{m,f} \| {m,f,args} \| nil` | `nil` | Hook called before execution |
| `after_execute` | `{m,f} \| {m,f,args} \| nil` | `nil` | Hook called after execution |
| `hook_timeout` | `pos_integer()` | `5_000` | Per-hook timeout in ms |
| `result_encoder` | `{m,f,args} \| nil` | `nil` | Applied to successful `{:ok, data}` sync results (see below) |
| `request_info` | `boolean` | `false` | Legacy field, currently unused in execution |

## Node Selection Strategies (`choose_node_mode`)

When a `FunConfig` has multiple nodes, the `NodeSelector` picks one:

| Strategy | Value | Description |
|----------|-------|-------------|
| Random | `:random` | Pick a random node |
| Hash (request_id) | `:hash` | Hash the `request_id` to pick a node |
| Hash (arg value) | `{:hash, "user_id"}` | Hash the value of the named arg |
| Round-robin | `:round_robin` | Cycle through nodes in order |
| Sticky | `{:sticky, "user_id"}` | Same key value always maps to the same node (persisted via ETS, survives restarts) |

**Use cases for sticky routing:** cache locality, session affinity, ordered processing per user.

### Dynamic node resolution

Instead of a static list, provide an MFA tuple that resolves at runtime:

```elixir
%FunConfig{
  nodes: {MyApp.Cluster, :get_nodes, ["user_service"]},
  choose_node_mode: :random
}
```

```elixir
defmodule MyApp.Cluster do
  def get_nodes(service_name) do
    # Query Consul, Kubernetes, DNS, etc.
    MyApp.Discovery.nodes_for(service_name)
  end
end
```

## Permission Modes (`check_permission`)

Four built-in modes plus custom callbacks.

| Mode | Value | Description |
|------|-------|-------------|
| Disabled | `false` | No permission check (default) |
| Any authenticated | `:any_authenticated` | Requires `user_id` to be non-nil |
| Arg-based | `{:arg, "user_id"}` | Compares `user_id` from socket to the named arg value |
| Role-based | `{:role, ["admin"]}` | Checks if any user role is in the allowed list |

### Any authenticated

Requires a non-nil `user_id`. Set `user_id` in `socket.assigns` (typically in `UserSocket.connect/3`):

```elixir
# In your socket:
def connect(params, socket, _connect_info) do
  {:ok, assign(socket, :user_id, params["user_id"])}
end

# In your FunConfig:
%FunConfig{
  request_type: "get_profile",
  service: "user_service",
  check_permission: :any_authenticated
  # ...
}
```

> Note: `use PhoenixGenApi` also defaults to `require_verified_user_id: true`, which rejects requests from sockets without a verified `user_id` before they even reach permission checks. See [Getting Started — Troubleshooting](./getting_started.md#troubleshooting).

### Arg-based (users access only their own data)

The specified argument must match the authenticated `user_id`:

```elixir
%FunConfig{
  request_type: "get_user_profile",
  service: "user_service",
  check_permission: {:arg, "user_id"},
  arg_types: %{"user_id" => :string}
  # ...
}
```

```elixir
# ✅ user_id from socket: "user_123", args: %{"user_id" => "user_123"} → allowed
# ❌ user_id from socket: "user_123", args: %{"user_id" => "user_999"} → denied
```

**Security note**: The `user_id` is always taken from `socket.assigns`, never from the client payload. Clients cannot spoof another user's ID.

### Role-based (RBAC)

The user must have at least one of the allowed roles. Roles are set in `socket.assigns`:

```elixir
# In your socket:
def connect(params, socket, _connect_info) do
  {:ok, assign(socket, :user_id, params["user_id"])
        |> assign(:user_roles, params["roles"] || [])}
end

# In your FunConfig:
%FunConfig{
  request_type: "delete_user",
  service: "admin_service",
  check_permission: {:role, ["admin"]}
  # ...
}
```

### Custom callback

Override all built-in checks with your own function:

```elixir
defmodule MyApp.Permissions do
  alias PhoenixGenApi.Structs.Request

  def check(%Request{} = request, _fun_config) do
    case MyApp.authorized?(request.user_id, request.request_type) do
      true -> :ok
      false -> {:error, :unauthorized}
    end
  end
end

# In your FunConfig:
%FunConfig{
  request_type: "admin_action",
  service: "admin_service",
  check_permission: false,  # Disable built-in checks
  permission_callback: {MyApp.Permissions, :check, []}
  # ...
}
```

The callback receives the `%Request{}` struct and must return `:ok` or `{:error, reason}`. Exceptions are caught and treated as denied (fail-closed).

## Response Types (`response_type`)

| Type | Description |
|------|-------------|
| `:sync` | Execute and return the result immediately |
| `:async` | Acknowledge immediately, send result later via `{:async_call, result}` |
| `:stream` | Start a `StreamCall` GenServer that sends chunks via `{:stream_response, result}` |
| `:none` | Fire-and-forget; no response sent to the client |

## Retry & Node Fallback (`retry`)

### Node fallback (no retry)

Even without retry configured, the executor tries all nodes in the list. If `node1` is down, it automatically tries `node2`, then `node3`.

### Retry configuration

| Value | Description |
|-------|-------------|
| `nil` | No retry (default) |
| `3` | Equivalent to `{:all_nodes, 3}` |
| `{:same_node, 2}` | Retry on the originally selected node(s) |
| `{:all_nodes, 3}` | Retry across all available nodes |

```elixir
# Retry across all nodes, up to 5 total attempts
%FunConfig{
  request_type: "get_data",
  service: "data_service",
  nodes: [:"node1@host", :"node2@host", :"node3@host"],
  mfa: {MyApp.Api, :get_data, []},
  retry: {:all_nodes, 5},
  response_type: :sync
}
```

### Retry flow

```
Attempt 1: node1 → failure
    |
    +-- {:same_node, 3} -> wait backoff -> retry node1
    +-- {:all_nodes, 3} -> try node2
    +-- 3               -> try node2
    |
Attempt 2: node1 or node2 -> failure
    |
    +-- same pattern...
    |
Attempt 3: final attempt -> failure
    |
    +-- Emit [:executor, :retry, :exhausted] telemetry
    +-- Return error response with can_retry: false
```

### Exponential backoff

Between retries, the executor waits `2^attempt * 100ms` — this prevents thundering herd problems during recovery.

## Argument Types (`arg_types`)

PhoenixGenApi validates every argument before calling your function. Two formats are supported.

### Simple format (type atoms)

```elixir
arg_types: %{
  "user_id" => :string,
  "age" => :num,
  "active" => :boolean
}
```

### Extended format (with constraints)

```elixir
arg_types: %{
  "title" => [type: :string, max_bytes: 200],
  "tags" => [type: :list_string, max_items: 10, max_item_bytes: 50],
  "published" => [type: :boolean, default_value: false],
  "metadata" => [type: :map, max_items: 50, required: ["author"], accept: ["author", "email"]]
}
```

### Available types

| Type | Description |
|------|-------------|
| `:string` | UTF-8 binary |
| `:num` | Integer or float |
| `:boolean` | `true` or `false` |
| `:uuid` | UUID string |
| `:datetime` | ISO 8601 datetime string |
| `:naive_datetime` | ISO 8601 naive datetime string |
| `:list` | List of any values |
| `:list_string` | List of strings |
| `:list_num` | List of numbers |
| `:list_uuid` | List of UUIDs |
| `:list_map` | List of maps |
| `:map` | String-keyed map |
| `:any` | Skip type checking |

### Extended format options

| Option | Applies to | Description |
|--------|-----------|-------------|
| `max_bytes:` | `:string` | Maximum byte length |
| `max_items:` | All list/map types | Maximum number of items |
| `max_item_bytes:` | `:list_string` | Max bytes per list item |
| `allow_nil?:` | All types | Allow `nil` values (default: `false`) |
| `default_value:` | All types | Default if arg is missing |
| `required:` | `:map` only | List of required map keys |
| `accept:` | `:map` only | List of allowed map keys (rejects unknown keys) |

### Argument ordering (`arg_orders`)

How validated args reach your function:

- `arg_orders: :map` — your function receives the args **map** directly:

```elixir
%FunConfig{
  request_type: "search",
  service: "search_service",
  mfa: {MyApp.Search, :search, []},
  arg_types: %{
    "query" => [type: :string, max_bytes: 500],
    "limit" => [type: :num, default_value: 20]
  },
  arg_orders: :map,
  response_type: :sync
}
```

```elixir
defmodule MyApp.Search do
  def search(%{"query" => query, "limit" => limit}) do
    # ...
  end
end
```

- `arg_orders: ["user_id", "fields"]` — your function receives the values as **positional arguments** in that order.
- `arg_orders: []` — allowed with a single-argument function; the single validated arg is passed directly.
- **When `arg_types` is set, `arg_orders` must also be set** (as a list or `:map`) — there is no default.

### Validation errors

If validation fails, the client gets an error response — your function is never called:

```elixir
# Sending a missing required field:
PhoenixGenApi.Executor.execute!(%Request{
  request_id: "test_1",
  service: "user_service",
  request_type: "get_user",
  args: %{}  # missing "user_id"
})
# => %Response{request_id: "test_1", success: false, error: "Missing required argument: user_id"}
```

## Function Versioning

Run multiple versions of the same API side-by-side:

```elixir
# Version 1.0.0
ConfigDb.add(%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "1.0.0",
  nodes: [Node.self()],
  choose_node_mode: :random,
  timeout: 5_000,
  mfa: {MyApp.Users, :get_user_v1, []},
  response_type: :sync
})

# Version 2.0.0 — adds field filtering
ConfigDb.add(%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "2.0.0",
  nodes: [Node.self()],
  choose_node_mode: :random,
  timeout: 5_000,
  mfa: {MyApp.Users, :get_user_v2, []},
  arg_types: %{"id" => :string, "fields" => [type: :list_string, max_items: 10]},
  arg_orders: ["id", "fields"],
  response_type: :sync
})
```

The client specifies the version in the request payload (`"version": "2.0.0"`). If no version is sent, the config with `nil` version is used.

### Version management at runtime

```elixir
{:ok, config} = ConfigDb.get("user_service", "get_user", "1.0.0")
{:ok, latest} = ConfigDb.get_latest("user_service", "get_user")

:ok = ConfigDb.disable("user_service", "get_user", "1.0.0")  # soft-delete; calls return {:error, :disabled}
:ok = ConfigDb.enable("user_service", "get_user", "1.0.0")
:ok = ConfigDb.delete("user_service", "get_user", "1.0.0")

ConfigDb.get_all_functions()
# => %{"user_service" => %{"get_user" => ["1.0.0", "2.0.0"]}}
```

The value `"0.0.0"` is reserved as a sentinel (meaning "no version") and cannot be explicitly registered.

## Hooks

Run custom code before and/or after function execution.

### Define hook modules

```elixir
defmodule MyApp.Hooks do
  require Logger

  # Called before execution
  # Must return {:ok, request, fun_config} or {:error, reason}
  def validate_quota(request, fun_config) do
    case MyApp.Quota.check(request.user_id) do
      :ok ->
        {:ok, request, fun_config}

      {:error, :quota_exceeded} ->
        {:error, "Quota exceeded. Upgrade your plan."}
    end
  end

  # Called after execution
  # Must return the (possibly modified) result
  def log_response(request, fun_config, result) do
    Logger.info("API call: #{request.service}/#{request.request_type} by #{request.user_id}")
    result
  end
end
```

### Configure hooks in FunConfig

```elixir
%FunConfig{
  request_type: "expensive_operation",
  service: "data_service",
  nodes: [Node.self()],
  choose_node_mode: :random,
  timeout: 5_000,
  mfa: {MyApp.Api, :expensive_operation, []},
  response_type: :sync,
  before_execute: {MyApp.Hooks, :validate_quota},
  after_execute: {MyApp.Hooks, :log_response},
  hook_timeout: 5_000  # per-hook timeout in ms
}
```

Hooks can also receive extra arguments: `before_execute: {MyApp.Hooks, :enrich_request, ["extra_value", 42]}`.

### Hook behavior

| Scenario | Behavior |
|----------|----------|
| Before hook returns `{:ok, req, config}` | Proceed with (possibly modified) request/config |
| Before hook returns `{:error, reason}` | Abort, return error response |
| Before hook times out | Abort, return timeout error |
| Before hook crashes | Abort, return crash error |
| After hook returns a value | Use the returned value as the result |
| After hook fails/times out | Original result is preserved (silently ignored) |

Hooks emit telemetry: `[:phoenix_gen_api, :hook, :before/:after, :start/:stop/:exception]`.

## Result Encoder (`result_encoder`)

An optional MFA applied to **successful sync results** — useful for redaction, compression, or wire-format conversion:

```elixir
%FunConfig{
  request_type: "get_profile",
  service: "user_service",
  mfa: {MyApp.Api, :get_profile, []},
  response_type: :sync,
  result_encoder: {MyApp.Redactor, :encode, []}
}
```

Contract:

- The encoder receives **only the unwrapped `data`** from `{:ok, data}`, followed by the tuple's `args`.
- Its return value is re-wrapped as `{:ok, encoded}`.
- `{:error, reason}` results pass through **untouched**.
- **`:stream` endpoints are not encoded** — streaming behavior is unchanged.
- Encoder MFA is checked against the MFA allowlist (when configured) at call time.
- Encoder failures (raise/throw/bad return) are caught and converted to `{:error, "result encoding failed: ..."}`.

## Validation

Use `FunConfig.valid?/1` for a quick boolean check or `FunConfig.validate_with_details/1` for detailed error messages:

```elixir
case FunConfig.validate_with_details(config) do
  {:ok, _} -> :valid
  {:error, errors} -> IO.inspect(errors)
end
```

Validation checks include: `request_type` is non-empty, `service` is not nil, `nodes` is valid, `choose_node_mode` is recognized, `timeout` is within bounds, `mfa` is a valid tuple, `arg_types` and `arg_orders` are consistent, `response_type` is valid, `check_permission` is valid, `retry` is valid, hooks and `result_encoder` are valid MFAs, `hook_timeout` is positive.

## Example

```elixir
alias PhoenixGenApi.Structs.FunConfig

%FunConfig{
  request_type: "get_user",
  service: "user_service",
  nodes: [:"node1@host", :"node2@host"],
  choose_node_mode: {:sticky, "user_id"},
  timeout: 5_000,
  mfa: {MyApp.Api, :get_user, []},
  arg_types: %{
    "user_id" => :string,
    "fields" => [type: :list_string, max_items: 10]
  },
  arg_orders: ["user_id", "fields"],
  response_type: :sync,
  version: "2.0.0",
  check_permission: {:arg, "user_id"},
  retry: {:all_nodes, 3},
  before_execute: {MyApp.Hooks, :validate_quota},
  after_execute: {MyApp.Hooks, :log_response}
}
```

---

## What's Next

- **[Getting Started](./getting_started.md)** — the full walkthrough from a single node to a cluster.
- **[Configuration](./configuration.md)** — Application-level configuration reference.
- **[Architecture](./architecture.md)** — How FunConfig fits into the system architecture.
