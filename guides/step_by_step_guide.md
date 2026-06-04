# PhoenixGenApi — Step-by-Step Guide

A complete walkthrough of every major feature, with code examples you can copy and run.

## Table of Contents

1. [Basic Setup — Sync API](#1-basic-setup--sync-api)
2. [Argument Validation](#2-argument-validation)
3. [Permissions](#3-permissions)
4. [Rate Limiting](#4-rate-limiting)
5. [Async Execution](#5-async-execution)
6. [Streaming](#6-streaming)
7. [Config Push vs Pull](#7-config-push-vs-pull)
8. [Function Versioning](#8-function-versioning)
9. [Retry & Node Fallback](#9-retry--node-fallback)
10. [Node Selection Strategies](#10-node-selection-strategies)
11. [Hooks](#11-hooks)
12. [Relay Messages](#12-relay-messages)
13. [Security](#13-security)
14. [Telemetry](#14-telemetry)
15. [Testing](#15-testing)
16. [IEx Helpers](#16-iex-helpers)

---

## 1. Basic Setup — Sync API

The simplest possible setup: a service node exposes a function, the gateway proxies it over WebSocket.

### Step 1 — Define your API module

```elixir
# lib/my_app/api.ex
defmodule MyApp.Api do
  @users [
    %{id: "1", name: "Alice", email: "alice@example.com"},
    %{id: "2", name: "Bob", email: "bob@example.com"}
  ]

  def list_users do
    {:ok, @users}
  end

  def get_user(user_id) do
    case Enum.find(@users, &(&1.id == user_id)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end
end
```

### Step 2 — Create the Supporter module

This module tells the gateway what functions are available and how to call them.

```elixir
# lib/my_app/gen_api/supporter.ex
defmodule MyApp.GenApi.Supporter do
  alias PhoenixGenApi.Structs.FunConfig

  def get_config(_arg) do
    {:ok, fun_configs()}
  end

  defp fun_configs do
    [
      %FunConfig{
        request_type: "list_users",
        service: "user_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyApp.Api, :list_users, []},
        arg_types: nil,
        response_type: :sync,
        version: "1.0.0"
      },
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

### Step 3 — Create the Channel

```elixir
# lib/my_app_web/channels/api_channel.ex
defmodule MyAppWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"

  def join("api:lobby", _payload, socket) do
    {:ok, socket}
  end
end
```

`use PhoenixGenApi` automatically injects:
- `handle_in("api", payload, socket)` — decodes and executes requests
- `handle_info({:push, result}, socket)` — pushes sync results to the client
- `handle_info({:async_call, result}, socket)` — pushes async results
- `handle_info({:stream_response, result}, socket)` — pushes stream chunks
- `handle_info({:relay_message, result}, socket)` — pushes relay messages

### Step 4 — Register the channel in your socket

```elixir
# lib/my_app_web/channels/user_socket.ex
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  channel "api:lobby", MyAppWeb.ApiChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
```

### Step 5 — Configure the gateway

```elixir
# config/config.exs
import Config

# Pull config from the service node every 30 seconds
config :phoenix_gen_api, :gen_api,
  pull_timeout: 5_000,
  pull_interval: 30_000,
  service_configs: [
    %{
      service: "user_service",
      nodes: [:"my_service@127.0.0.1"],
      module: MyApp.GenApi.Supporter,
      function: :get_config,
      args: []
    }
  ]
```

### Step 6 — Test from IEx

```elixir
alias PhoenixGenApi.Structs.Request

# Call list_users
request = %Request{
  request_id: "test_1",
  service: "user_service",
  request_type: "list_users",
  args: %{}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_1", success: true, result: [%{id: "1", name: "Alice", ...}, ...]}

# Call get_user
request = %Request{
  request_id: "test_2",
  service: "user_service",
  request_type: "get_user",
  args: %{"user_id" => "1"}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_2", success: true, result: %{id: "1", name: "Alice", ...}}
```

### Step 7 — Test from JavaScript

```javascript
const socket = new Phoenix.Socket("ws://localhost:4000/socket", {});
socket.connect();

const channel = socket.channel("api:lobby", {});

channel.on("api", payload => {
  console.log("Response:", payload);
});

channel.join().receive("ok", () => {
  // List all users
  channel.push("api", {
    service: "user_service",
    request_type: "list_users",
    request_id: "req_" + Date.now()
  });

  // Get a specific user
  channel.push("api", {
    service: "user_service",
    request_type: "get_user",
    request_id: "req_" + Date.now(),
    args: { user_id: "1" }
  });
});
```

---

## 2. Argument Validation

PhoenixGenApi validates every argument before calling your function. Two formats are supported.

### Simple format (type atoms)

```elixir
%FunConfig{
  request_type: "get_user",
  service: "user_service",
  nodes: [Node.self()],
  mfa: {MyApp.Api, :get_user, []},
  arg_types: %{
    "user_id" => :string,
    "age" => :num,
    "active" => :boolean,
    "tags" => :list_string,
    "metadata" => :map
  },
  arg_orders: ["user_id", "age", "active", "tags", "metadata"],
  response_type: :sync
}
```

### Extended format (with constraints)

```elixir
%FunConfig{
  request_type: "create_post",
  service: "blog_service",
  nodes: [Node.self()],
  mfa: {MyApp.Blog, :create_post, []},
  arg_types: %{
    "title" => [type: :string, max_bytes: 200],
    "body" => [type: :string, max_bytes: 50_000],
    "tags" => [type: :list_string, max_items: 10, max_item_bytes: 50],
    "published" => [type: :boolean, default_value: false],
    "metadata" => [
      type: :map,
      max_items: 50,
      required: ["author"],
      accept: ["author", "category", "thumbnail"]
    ]
  },
  arg_orders: ["title", "body", "tags", "published", "metadata"],
  response_type: :sync
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

### Map-style arguments (no ordering)

Use `arg_orders: :map` to pass arguments as a single map to your function:

```elixir
%FunConfig{
  request_type: "search",
  service: "search_service",
  nodes: [Node.self()],
  mfa: {MyApp.Search, :search, []},
  arg_types: %{
    "query" => [type: :string, max_bytes: 500],
    "limit" => [type: :num, default_value: 20],
    "offset" => [type: :num, default_value: 0]
  },
  arg_orders: :map,
  response_type: :sync
}
```

Your function receives the args map directly:

```elixir
defmodule MyApp.Search do
  def search(%{"query" => query, "limit" => limit, "offset" => offset}) do
    # ...
  end
end
```

### Validation errors

If validation fails, the client gets an error response — your function is never called:

```elixir
# Sending a missing required field:
request = %Request{
  request_id: "test_1",
  service: "user_service",
  request_type: "get_user",
  args: %{}  # missing "user_id"
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_1", success: false, error: "Missing required argument: user_id"}
```

---

## 3. Permissions

Four built-in permission modes plus custom callbacks.

### Disabled (default)

No check. Anyone can call the function.

```elixir
%FunConfig{
  request_type: "search",
  service: "public_service",
  check_permission: false,
  # ...
}
```

### Any authenticated

Requires a non-nil `user_id`. Set `user_id` in `socket.assigns` during `join/3`:

```elixir
# In your channel:
def join("api:lobby", _payload, socket) do
  {:ok, assign(socket, :user_id, "user_42")}
end

# In your FunConfig:
%FunConfig{
  request_type: "get_profile",
  service: "user_service",
  check_permission: :any_authenticated,
  # ...
}
```

### Arg-based (users access only their own data)

The specified argument must match the authenticated `user_id`:

```elixir
%FunConfig{
  request_type: "get_user_profile",
  service: "user_service",
  check_permission: {:arg, "user_id"},
  arg_types: %{"user_id" => :string},
  # ...
}
```

```elixir
# ✅ user_id from socket: "user_123", args: %{"user_id" => "user_123"} → allowed
# ❌ user_id from socket: "user_123", args: %{"user_id" => "user_999"} → denied
```

**Security note**: The `user_id` is always taken from `socket.assigns`, never from the client payload. Clients cannot spoof another user's ID.

### Role-based (RBAC)

The user must have at least one of the allowed roles. Roles are set in `socket.assigns` during `join/3`:

```elixir
# In your channel:
def join("api:lobby", _payload, socket) do
  {:ok, assign(socket, :user_id, "user_42", :user_roles, ["admin", "editor"])}
end

# In your FunConfig:
%FunConfig{
  request_type: "delete_user",
  service: "admin_service",
  check_permission: {:role, ["admin"]},
  # ...
}
```

```elixir
# ✅ user_roles: ["admin", "editor"], allowed: ["admin"] → allowed
# ❌ user_roles: ["viewer"], allowed: ["admin"] → denied
```

### Custom callback

Override all built-in checks with your own function:

```elixir
# Define the callback module
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
  permission_callback: {MyApp.Permissions, :check, []},
  # ...
}
```

The callback receives the `%Request{}` struct and must return `:ok` or `{:error, reason}`. Exceptions are caught and treated as denied (fail-closed).

---

## 4. Rate Limiting

Sliding-window rate limiter with global and per-API limits.

### Enable rate limiting

```elixir
# config/config.exs
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  fail_open: true,
  global_limits: [
    # 1 000 requests per minute per user
    %{key: :user_id, max_requests: 1000, window_ms: 60_000},
    # 5 000 requests per minute per device
    %{key: :device_id, max_requests: 5000, window_ms: 60_000}
  ],
  api_limits: [
    # Expensive endpoint: 10 requests per minute per user
    %{
      service: "report_service",
      request_type: "generate_report",
      key: :user_id,
      max_requests: 10,
      window_ms: 60_000
    }
  ]
```

### How it works

1. **Global limits** apply to every request regardless of which function is called.
2. **Per-API limits** apply only to the specified `{service, request_type}` pair.
3. If *any* limit is exceeded, the request is rejected before your function is called.

### Check rate limits programmatically

```elixir
alias PhoenixGenApi.RateLimiter

# Check using a Request struct
case RateLimiter.check_rate_limit(request) do
  :ok ->
    # Proceed with execution
    PhoenixGenApi.Executor.execute!(request)

  {:error, :rate_limited, details} ->
    # details.retry_after_ms tells the client when to retry
    %{
      error: "Rate limit exceeded",
      retry_after_ms: details.retry_after_ms
    }
end

# Check a specific limit directly
RateLimiter.check_rate_limit("user_123", :global, :user_id)
RateLimiter.check_rate_limit("user_123", {"report_service", "generate_report"}, :user_id)
```

### Runtime configuration

```elixir
# Add a new global limit
RateLimiter.add_global_limit(%{
  key: :ip_address,
  max_requests: 5000,
  window_ms: 60_000
})

# Remove a limit
RateLimiter.remove_global_limit(:ip_address)

# Reset a specific user's rate limit
RateLimiter.reset_rate_limit("user_123", :global, :user_id)

# Check a user's current status
RateLimiter.get_rate_limit_status("user_123", :global, :user_id)
# => %{current: 42, max: 1000, window_ms: 60_000, remaining: 958}

# Replace all limits at once
RateLimiter.update_config(%{
  enabled: true,
  global_limits: [%{key: :user_id, max_requests: 2000, window_ms: 60_000}],
  api_limits: []
})
```

### Fail-open behavior

When `fail_open: true` (the default), if the rate limiter encounters an internal error, it **allows the request through** rather than blocking all traffic. Set `fail_open: false` to reject requests when the rate limiter is unhealthy.

---

## 5. Async Execution

For long-running operations, use `response_type: :async` to return immediately and send the result later.

### Define an async function

```elixir
# lib/my_app/api.ex
defmodule MyApp.Api do
  def generate_report(args) do
    # This runs in a worker pool process, not the channel process
    # Simulate long work
    :timer.sleep(3_000)
    {:ok, %{report_url: "https://example.com/reports/123.pdf"}}
  end
end
```

### Create the FunConfig

```elixir
%FunConfig{
  request_type: "generate_report",
  service: "report_service",
  nodes: [Node.self()],
  mfa: {MyApp.Api, :generate_report, []},
  arg_types: %{"format" => [type: :string, default_value: "pdf"]},
  arg_orders: ["format"],
  response_type: :async,
  version: "1.0.0"
}
```

### What happens

```
Client                    Gateway Channel              Worker Pool
  │                            │                          │
  │  push("api", payload)      │                          │
  │───────────────────────────►│                          │
  │                            │                          │
  │  %Response{async: true}    │  spawn on worker pool   │
  │◄───────────────────────────│─────────────────────────►│
  │                            │                          │
  │                            │         ... working ...  │
  │                            │                          │
  │                            │  {:async_call, result}   │
  │                            │◄─────────────────────────│
  │  %Response{result: ...}    │                          │
  │◄───────────────────────────│                          │
```

The client receives two messages:
1. An immediate `{async: true}` acknowledgment.
2. The actual result when the worker finishes.

### JavaScript client handling

```javascript
channel.on("api", payload => {
  if (payload.async && !payload.has_more) {
    console.log("Request accepted, waiting for result...");
  } else if (payload.result) {
    console.log("Got result:", payload.result);
  }
});
```

---

## 6. Streaming

For functions that produce a sequence of results, use `response_type: :stream`.

### Define a streaming function

Your function receives a `StreamHelper` struct that you use to send chunks:

```elixir
# lib/my_app/api.ex
defmodule MyApp.Api do
  alias PhoenixGenApi.Structs.StreamHelper

  def stream_events(%StreamHelper{} = stream) do
    # Send intermediate chunks
    Enum.each(1..10, fn i ->
      StreamHelper.send_result(stream, %{event: "tick", number: i})
      :timer.sleep(500)
    end)

    # Send the final chunk
    StreamHelper.send_last_result(stream, %{event: "done", total: 10})
  end

  # Alternative: send chunks and signal completion separately
  def stream_search(%StreamHelper{} = stream) do
    results = MyApp.Search.all()

    Enum.each(results, fn batch ->
      StreamHelper.send_result(stream, batch)
    end)

    StreamHelper.send_complete(stream)
  end
end
```

### Create the FunConfig

```elixir
%FunConfig{
  request_type: "stream_events",
  service: "event_service",
  nodes: :local,
  mfa: {MyApp.Api, :stream_events, []},
  arg_types: nil,
  response_type: :stream,
  version: "1.0.0"
}
```

### StreamHelper API

| Function | Description |
|----------|-------------|
| `StreamHelper.send_result(stream, data)` | Send an intermediate chunk (`has_more: true`) |
| `StreamHelper.send_last_result(stream, data)` | Send the final chunk (`has_more: false`) |
| `StreamHelper.send_complete(stream)` | Signal stream end without data |
| `StreamHelper.send_error(stream, reason)` | Send an error and end the stream |

### Stopping a stream

```elixir
# Stop by request_id
PhoenixGenApi.stop_stream("req_123")

# Stop by PID
PhoenixGenApi.stop_stream(stream_pid)
```

### JavaScript client handling

```javascript
channel.on("api", payload => {
  if (payload.has_more) {
    console.log("Chunk:", payload.result);
  } else if (payload.async) {
    console.log("Stream complete");
  }
});
```

---

## 7. Config Push vs Pull

Two ways to register your functions on the gateway.

### Pull mode (gateway fetches from service)

The gateway periodically calls your Supporter module on the service node.

**On the service node** — define a Supporter:

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

  # Optional: version check function for efficient polling
  def get_config_version, do: "1.0.0"
end
```

**On the gateway** — configure the puller:

```elixir
config :phoenix_gen_api, :gen_api,
  pull_timeout: 5_000,
  pull_interval: 30_000,
  service_configs: [
    %{
      service: "user_service",
      nodes: [:"my_service@127.0.0.1"],
      module: MyApp.GenApi.Supporter,
      function: :get_config,
      args: [],
      # Optional: skip full pull if version hasn't changed
      version_module: MyApp.GenApi.Supporter,
      version_function: :get_config_version,
      version_args: []
    }
  ]
```

### Push mode (service registers on gateway)

The service node pushes its config to the gateway on startup.

```elixir
# In your service node's application.ex or a GenServer
alias PhoenixGenApi.ConfigPusher
alias PhoenixGenApi.Structs.FunConfig

fun_configs = [
  %FunConfig{
    request_type: "get_user",
    service: :user_service,
    nodes: [Node.self()],
    mfa: {MyApp.Api, :get_user, []},
    arg_types: %{"user_id" => :string},
    response_type: :sync,
    version: "1.0.0"
  }
]

push_config = ConfigPusher.from_service_config(
  :user_service,
  [Node.self()],
  fun_configs,
  config_version: "1.0.0",
  # Optional: enable periodic pull after initial push
  module: MyApp.GenApi.Supporter,
  function: :get_config
)

# Push on startup
ConfigPusher.push_on_startup(:"gateway@127.0.0.1", push_config)
```

### Push with verification

```elixir
case ConfigPusher.verify(:"gateway@127.0.0.1", :user_service, "1.0.0") do
  {:ok, :matched} ->
    IO.puts("Already registered with this version")

  {:ok :mismatch, stored_version} ->
    IO.puts("Version mismatch: gateway has #{stored_version}, pushing update")
    ConfigPusher.push(:"gateway@127.0.0.1", push_config)

  {:error, :not_found} ->
    IO.puts("Service not registered, pushing initial config")
    ConfigPusher.push(:"gateway@127.0.0.1", push_config)
end
```

### Push with authentication

```elixir
# On the gateway:
config :phoenix_gen_api, :push_token, "my-secret-token"

# On the service node — the token is read automatically from config:
push_config = ConfigPusher.from_service_config(
  :user_service,
  [Node.self()],
  fun_configs,
  config_version: "1.0.0"
)
# push_token is automatically included from Application.get_env(:phoenix_gen_api, :push_token)
```

### Comparison

| Aspect | Pull | Push |
|--------|------|------|
| Who initiates | Gateway | Service node |
| Delay | Up to `pull_interval` | Immediate on startup |
| Auto-refresh | Yes (periodic) | Only if `module`/`function` provided |
| Version skip | Yes (with `version_module`) | Yes (idempotent by `config_version`) |
| Use case | Many services, dynamic | Fast registration, few services |

---

## 8. Function Versioning

Run multiple versions of the same API side-by-side.

### Register multiple versions

```elixir
alias PhoenixGenApi.ConfigDb

# Version 1.0.0 — returns all fields
ConfigDb.add(%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "1.0.0",
  nodes: [Node.self()],
  mfa: {MyApp.Users, :get_user_v1, []},
  arg_types: %{"id" => :string},
  response_type: :sync
})

# Version 2.0.0 — adds field filtering
ConfigDb.add(%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "2.0.0",
  nodes: [Node.self()],
  mfa: {MyApp.Users, :get_user_v2, []},
  arg_types: %{
    "id" => :string,
    "fields" => [type: :list_string, max_items: 10]
  },
  arg_orders: ["id", "fields"],
  response_type: :sync
})
```

### Client specifies version

```json
{
  "service": "user_service",
  "request_type": "get_user",
  "request_id": "req_1",
  "version": "2.0.0",
  "args": { "id": "123", "fields": ["name", "email"] }
}
```

If no `version` is sent, the gateway uses the config with `nil` version (or `"0.0.0"` sentinel).

### Version management at runtime

```elixir
# Get a specific version
{:ok, config} = ConfigDb.get("user_service", "get_user", "1.0.0")

# Get the latest enabled version
{:ok, latest} = ConfigDb.get_latest("user_service", "get_user")

# Disable a version (soft-delete)
:ok = ConfigDb.disable("user_service", "get_user", "1.0.0")
# Calls to v1 now return {:error, :disabled}

# Re-enable
:ok = ConfigDb.enable("user_service", "get_user", "1.0.0")

# Delete permanently
:ok = ConfigDb.delete("user_service", "get_user", "1.0.0")

# List all functions and their versions
ConfigDb.get_all_functions()
# => %{"user_service" => %{"get_user" => ["1.0.0", "2.0.0"]}}
```

### Reserved sentinel

The value `"0.0.0"` is reserved and cannot be explicitly registered. It's used internally to mean "no version specified". If you try to add a config with `version: "0.0.0"`, it will be stored with a `nil` version key.

---

## 9. Retry & Node Fallback

### Node fallback (no retry)

Even without retry configured, the executor tries all nodes in the list:

```elixir
%FunConfig{
  request_type: "get_data",
  service: "data_service",
  nodes: [:"node1@host", :"node2@host", :"node3@host"],
  mfa: {MyApp.Api, :get_data, []},
  response_type: :sync
}
```

If `node1` is down, the executor automatically tries `node2`, then `node3`.

### Retry configuration

```elixir
# Retry 3 times on the same node (useful for transient failures)
%FunConfig{
  request_type: "get_data",
  service: "data_service",
  nodes: [:"node1@host", :"node2@host"],
  mfa: {MyApp.Api, :get_data, []},
  retry: {:same_node, 3},
  response_type: :sync
}

# Retry across all nodes, up to 5 total attempts
%FunConfig{
  request_type: "get_data",
  service: "data_service",
  nodes: [:"node1@host", :"node2@host", :"node3@host"],
  mfa: {MyApp.Api, :get_data, []},
  retry: {:all_nodes, 5},
  response_type: :sync
}

# Simple number (equivalent to {:all_nodes, 3})
%FunConfig{
  request_type: "get_data",
  service: "data_service",
  nodes: [:"node1@host", :"node2@host"],
  mfa: {MyApp.Api, :get_data, []},
  retry: 3,
  response_type: :sync
}
```

### Retry flow

```
Attempt 1: node1 → failure
    │
    ├─ {:same_node, 3} → wait backoff → retry node1
    ├─ {:all_nodes, 3} → try node2
    └─ 3 → try node2
    │
Attempt 2: node1 or node2 → failure
    │
    ├─ {:same_node, 3} → wait backoff → retry node1
    ├─ {:all_nodes, 3} → try node3
    └─ 3 → try node3
    │
Attempt 3: final attempt → failure
    │
    └─ Emit [:executor, :retry, :exhausted] telemetry
    └─ Return error response with can_retry: false
```

### Exponential backoff

Between retries, the executor waits `2^attempt * 100ms`. This prevents thundering herd problems during recovery.

---

## 10. Node Selection Strategies

When a `FunConfig` has multiple nodes, the `NodeSelector` picks one:

### Random (default)

```elixir
%FunConfig{
  choose_node_mode: :random,
  nodes: [:"node1@host", :"node2@host", :"node3@host"]
}
```

### Hash by request_id

```elixir
%FunConfig{
  choose_node_mode: :hash,
  nodes: [:"node1@host", :"node2@host", :"node3@host"]
}
# Same request_id always goes to the same node
```

### Hash by argument value

```elixir
%FunConfig{
  choose_node_mode: {:hash, "user_id"},
  nodes: [:"node1@host", :"node2@host", :"node3@host"]
}
# Same user_id always goes to the same node
```

### Round-robin

```elixir
%FunConfig{
  choose_node_mode: :round_robin,
  nodes: [:"node1@host", :"node2@host", :"node3@host"]
}
# Cycles: node1 → node2 → node3 → node1 → ...
```

### Sticky (persistent mapping)

```elixir
%FunConfig{
  choose_node_mode: {:sticky, "user_id"},
  nodes: [:"node1@host", :"node2@host", :"node3@host"]
}
# Same user_id always goes to the same node, even across restarts
# (uses ETS to persist the mapping)
```

**Use cases for sticky routing:**
- Cache locality (user data cached on one node)
- Session affinity
- Ordered processing per user

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

---

## 11. Hooks

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

  # Hook with extra arguments
  def enrich_request(request, fun_config, extra_arg1, extra_arg2) do
    # extra_args are appended after request and fun_config
    {:ok, %{request | args: Map.put(request.args, "enriched", true)}, fun_config}
  end
end
```

### Configure hooks in FunConfig

```elixir
%FunConfig{
  request_type: "expensive_operation",
  service: "data_service",
  nodes: [Node.self()],
  mfa: {MyApp.Api, :expensive_operation, []},
  arg_types: nil,
  response_type: :sync,
  before_execute: {MyApp.Hooks, :validate_quota},
  after_execute: {MyApp.Hooks, :log_response},
  hook_timeout: 5_000  # per-hook timeout in ms (default: 5000)
}
```

### Hook with extra arguments

```elixir
%FunConfig{
  request_type: "process_data",
  service: "data_service",
  nodes: [Node.self()],
  mfa: {MyApp.Api, :process_data, []},
  before_execute: {MyApp.Hooks, :enrich_request, ["extra_value", 42]},
  response_type: :sync
}
```

### Hook behavior

| Scenario | Behavior |
|----------|----------|
| Before hook returns `{:ok, req, config}` | Proceed with (possibly modified) request/config |
| Before hook returns `{:error, reason}` | Abort, return error response |
| Before hook times out | Abort, return timeout error |
| Before hook crashes | Abort, return crash error |
| After hook returns a value | Use the returned value as the result |
| After hook fails/times out | Original result is preserved (silently ignored) |

### Telemetry from hooks

Hooks emit their own telemetry events:
- `[:phoenix_gen_api, :hook, :before, :start/:stop/:exception]`
- `[:phoenix_gen_api, :hook, :after, :start/:stop/:exception]`

---

## 12. Relay Messages

Group-based message broadcasting. A user sends a message to a group, and all members receive it.

### Step 1 — Create the relay FunConfig

```elixir
alias PhoenixGenApi.ConfigDb
alias PhoenixGenApi.Structs.FunConfig

ConfigDb.add(%FunConfig{
  request_type: "send_message",
  service: "chat_service",
  nodes: :local,
  mfa: {PhoenixGenApi.Relay, :handle_relay, []},
  arg_types: %{
    "group_id" => :string,
    "message" => [type: :string, max_bytes: 2000]
  },
  arg_orders: ["group_id", "message"],
  response_type: :sync,
  check_permission: :any_authenticated,
  version: "1.0.0"
})
```

### Step 2 — Create a chat channel

```elixir
defmodule MyAppWeb.ChatChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "chat"

  def join("chat:" <> group_id, _payload, socket) do
    # Auto-join the relay group when joining the channel
    case PhoenixGenApi.Relay.join_group(group_id, socket.assigns.user_id, self()) do
      {:ok, _status} -> {:ok, socket}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  # Handle relay messages from other users
  def handle_info({:relay_message, response}, socket) do
    push(socket, "chat", response.result)
    {:noreply, socket}
  end
end
```

### Step 3 — Manage groups

```elixir
# Create a public group (anyone can join immediately)
:ok = PhoenixGenApi.Relay.create_group("room_1", :public, "admin", admin_channel_pid)

# Create a private group (new members need approval)
:ok = PhoenixGenApi.Relay.create_group("room_2", :private, "admin", admin_channel_pid)

# Create a strict private group (only admin can accept/mute)
:ok = PhoenixGenApi.Relay.create_group("room_3", :strict_private, "admin", admin_channel_pid)

# Join a group
{:ok, :active} = PhoenixGenApi.Relay.join_group("room_1", "user_2", user2_channel_pid)

# For private groups: accept a pending member
:ok = PhoenixGenApi.Relay.accept_member("room_2", "admin", "user_2")

# For strict private groups: mute a member
:ok = PhoenixGenApi.Relay.mute_member("room_3", "admin", "user_2")
:ok = PhoenixGenApi.Relay.unmute_member("room_3", "admin", "user_2")

# Leave a group
:ok = PhoenixGenApi.Relay.leave_group("room_1", "user_2")

# Inspect group info
{:ok, info} = PhoenixGenApi.Relay.get_group_info("room_1")
# => %{group_id: "room_1", group_type: :public, members: %{"admin" => %{...}, "user_2" => %{...}}}

# Delete a group
:ok = PhoenixGenApi.Relay.delete_group("room_1")
```

### Step 4 — Send a relay message

From the client:

```javascript
channel.push("chat", {
  service: "chat_service",
  request_type: "send_message",
  request_id: "msg_" + Date.now(),
  args: {
    group_id: "room_1",
    message: "Hello everyone!"
  }
});
```

All members receive:

```json
{
  "request_id": "msg_123",
  "success": true,
  "result": {
    "group_id": "room_1",
    "from_user_id": "user_1",
    "message": "Hello everyone!",
    "timestamp": "2025-01-15T10:30:00Z"
  }
}
```

### Group type comparison

| Action | `:public` | `:private` | `:strict_private` |
|--------|-----------|------------|-------------------|
| Join | → `:active` | → `:pending` | → `:pending` |
| Accept | N/A | Any `:active` | Only `:admin` |
| Send | Any `:active` | Any `:active` | `:active` (not muted) |
| Receive | `:active` + `:muted` | `:active` + `:muted` | `:active` + `:muted` |
| Mute | ❌ | ❌ | Only `:admin` |

### Auto-cleanup

When a channel process dies (client disconnect, crash), `RelayServer` automatically removes the user from all groups it belonged to. No manual cleanup needed.

---

## 13. Security

### Admin gate

Restrict dangerous runtime operations:

```elixir
config :phoenix_gen_api,
  admin_actions: [:push_config, :update_rate_limit_config]
```

Available actions: `:push_config`, `:update_rate_limit_config`, `:change_detail_error`.

Default: empty list (deny everything).

### Push token

Authenticate push requests from service nodes:

```elixir
# On the gateway:
config :phoenix_gen_api, :push_token: "my-secret-token"

# On the service node:
config :phoenix_gen_api, :push_token: "my-secret-token"
# Automatically included in ConfigPusher.from_service_config/4
```

Token comparison uses constant-time binary comparison to prevent timing attacks.

### MFA allowlist

Restrict which functions can be registered:

```elixir
config :phoenix_gen_api,
  mfa_allowlist: [
    MyApp.UserService,                    # All functions in this module
    {MyApp.OrderService, :create_order}   # Only this specific function
  ]
```

**Hardcoded denylist**: `:os`, `:file`, `:code`, `:erlang`, `:net`, `:rpc`, `:global`, `:inet` are always blocked.

### Payload size limit

```elixir
config :phoenix_gen_api, :request, max_payload_bytes: 500_000
```

Default: 1MB. Checked **before** deserialization to prevent memory exhaustion.

### Detail error messages

By default, internal error details are hidden from clients:

```elixir
config :phoenix_gen_api, :gen_api, detail_error: false
```

When `false`, clients see `"Internal Server Error"` instead of the actual error message. Set to `true` only in development.

---

## 14. Telemetry

PhoenixGenApi emits 31 telemetry events across 5 categories.

### Attach to all events

```elixir
PhoenixGenApi.Telemetry.attach_all("my-app", fn event, measurements, metadata, _config ->
  Logger.info("[Telemetry] #{inspect(event)} duration=#{measurements[:duration_us]}")
end)
```

### Attach to specific categories

```elixir
# Only executor events (request start/stop/exception/retry)
PhoenixGenApi.Telemetry.attach_executor("my-app", &MyApp.handle_event/4)

# Only rate limiter events
PhoenixGenApi.Telemetry.attach_rate_limiter("my-app", &MyApp.handle_event/4)

# Only hook events
PhoenixGenApi.Telemetry.attach_hooks("my-app", &MyApp.handle_event/4)

# Only worker pool events
PhoenixGenApi.Telemetry.attach_worker_pool("my-app", &MyApp.handle_event/4)

# Only config cache events
PhoenixGenApi.Telemetry.attach_config("my-app", &MyApp.handle_event/4)
```

### Built-in debug logger

```elixir
PhoenixGenApi.Telemetry.attach_default_logger()
```

### Detach

```elixir
PhoenixGenApi.Telemetry.detach_all("my-app")
```

### Integration with Telemetry.Metrics

```elixir
defmodule MyApp.Metrics do
  def metrics do
    [
      # Request duration histogram
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.executor.request.duration_us",
        event_name: [:phoenix_gen_api, :executor, :request, :stop],
        measurement: :duration_us,
        tags: [:service, :request_type, :success]
      ),

      # Error counter
      Telemetry.Metrics.counter(
        "phoenix_gen_api.executor.exceptions.count",
        event_name: [:phoenix_gen_api, :executor, :request, :exception],
        tags: [:service, :request_type]
      ),

      # Rate limit exceeded counter
      Telemetry.Metrics.counter(
        "phoenix_gen_api.rate_limiter.exceeded.count",
        event_name: [:phoenix_gen_api, :rate_limiter, :exceeded],
        tags: [:key, :scope]
      ),

      # Circuit breaker gauge
      Telemetry.Metrics.last_value(
        "phoenix_gen_api.worker_pool.circuit_breaker",
        event_name: [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
        tags: [:pool_name]
      )
    ]
  end
end
```

### List all available events

```elixir
PhoenixGenApi.Telemetry.list_events()
```

---

## 15. Testing

### Test the Executor directly

```elixir
defmodule MyApp.ApiTest do
  use ExUnit.Case

  alias PhoenixGenApi.Structs.{Request, Response}

  test "get_user returns user data" do
    request = %Request{
      request_id: "test_1",
      service: "user_service",
      request_type: "get_user",
      args: %{"user_id" => "1"}
    }

    response = PhoenixGenApi.Executor.execute!(request)

    assert response.success == true
    assert response.request_id == "test_1"
    assert response.result.name == "Alice"
  end

  test "get_user returns error for unknown user" do
    request = %Request{
      request_id: "test_2",
      service: "user_service",
      request_type: "get_user",
      args: %{"user_id" => "nonexistent"}
    }

    response = PhoenixGenApi.Executor.execute!(request)

    assert response.success == false
    assert response.request_id == "test_2"
  end
end
```

### Test with a channel

```elixir
defmodule MyAppWeb.ApiChannelTest do
  use MyAppWeb.ChannelCase

  test "returns user data on get_user", %{socket: socket} do
    {:ok, _, socket} =
      socket
      |> subscribe_and_join(MyAppWeb.ApiChannel, "api:lobby", %{})

    ref = push(socket, "api", %{
      service: "user_service",
      request_type: "get_user",
      request_id: "req_1",
      args: %{"user_id" => "1"}
    })

    assert_reply ref, :ok, %{
      "success" => true,
      "request_id" => "req_1"
    }
  end
end
```

### Test argument validation

```elixir
test "rejects missing required argument" do
  request = %Request{
    request_id: "test_1",
    service: "user_service",
    request_type: "get_user",
    args: %{}  # missing "user_id"
  }

  response = PhoenixGenApi.Executor.execute!(request)
  assert response.success == false
  assert response.error =~ "Missing required argument"
end
```

### Test permissions

```elixir
test "denies access when user_id doesn't match arg" do
  request = %Request{
    request_id: "test_1",
    service: "user_service",
    request_type: "get_user_profile",
    user_id: "user_123",
    args: %{"user_id" => "user_999"}
  }

  response = PhoenixGenApi.Executor.execute!(request)
  assert response.success == false
  assert response.error =~ "Permission denied"
end
```

### Test rate limiting

```elixir
test "rate limits after max requests" do
  # Make max_requests + 1 calls
  request = %Request{
    request_id: "test_1",
    service: "user_service",
    request_type: "get_user",
    user_id: "user_123",
    args: %{"user_id" => "1"}
  }

  # First 100 calls succeed (assuming limit is 100)
  Enum.each(1..100, fn i ->
    req = %{request | request_id: "test_#{i}"}
    response = PhoenixGenApi.Executor.execute!(req)
    assert response.success == true
  end)

  # 101st call is rate limited
  req = %{request | request_id: "test_101"}
  response = PhoenixGenApi.Executor.execute!(req)
  assert response.success == false
  assert response.error =~ "Rate limit"
end
```

### Clean up telemetry handlers in tests

```elixir
setup do
  on_exit(fn ->
    PhoenixGenApi.Telemetry.detach_all("test-handler")
  end)

  :ok
end
```

---

## 16. IEx Helpers

Convenient functions for debugging and monitoring in IEx:

```elixir
# Check what's registered in the config cache
PhoenixGenApi.cache_status()

# Check worker pool status (idle/busy workers, queue size)
PhoenixGenApi.pool_status()

# Rate limit status for a user
PhoenixGenApi.rl_status("user_123")

# Show global rate limits
PhoenixGenApi.rl_global()

# Set global rate limits
PhoenixGenApi.rl_global([%{key: :user_id, max_requests: 500, window_ms: 60_000}])

# Show rate limiter config
PhoenixGenApi.rl_config()

# Check pushed services and their versions
PhoenixGenApi.pushed_services_status()

# List all telemetry events
PhoenixGenApi.Telemetry.list_events()

# Attach the debug logger
PhoenixGenApi.Telemetry.attach_default_logger()
```

---

## What's Next

- **[FunConfig Reference](./fun_config.md)** — Field-by-field reference for every FunConfig option.
- **[Configuration](./configuration.md)** — Application-level config: gateway, rate limiter, worker pool, security.
- **[Architecture Guide](./architecture.md)** — Deep dive into the supervision tree, request lifecycle, and all subsystems.
- **[Execute Flow](./execute_flow.md)** — Line-by-line walkthrough of the complete request execution path.
- **[Relay Messages Guide](./relay_messages.md)** — Complete reference for group types, permission matrix, and process monitoring.
- **[Telemetry Guide](./telemetry.md)** — Full event reference, integration patterns, and best practices.
