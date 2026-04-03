[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/phoenix_gen_api)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_gen_api.svg?style=flat&color=blue)](https://hex.pm/packages/phoenix_gen_api)

# PhoenixGenApi

The library helps quickly develop APIs for client, the library is based on Phoenix Channel.
Developers can add or update APIs in runtime from other nodes in the cluster without restarting or reconfiguring the Phoenix app.
In this case, the Phoenix app will take on the role of an API gateway.

The library can use with [EasyRpc](https://hex.pm/packages/easy_rpc) and [ClusterHelper](https://hex.pm/packages/cluster_helper) for fast and easy to develop a dynamic Elixir cluster.

## Concept

After received an event from client(in handle_in callback of Phoenix Channel), the event will be passed to PhoenixGenApi to find target API & target node to execute then get result for response to client.

For service nodes (target node), the libray support some basic strategy for selecting node (:choose_node_mode) like: :random, :hash, :round_robin.

Supported :sync, :async, :stream for request/response to client.

Supported basic check type & permission.

## Features

- **Dynamic Configuration**: Add/update APIs at runtime from remote nodes
- **Multi-Version Support**: Manage multiple API versions with enable/disable controls
- **Rate Limiting**: Sliding window rate limiter with global and per-API limits
- **Permission System**: Flexible authentication and authorization modes
- **Worker Pools**: Dedicated pools for async and stream operations
- **Node Selection**: Random, hash-based, and round-robin strategies
- **Response Types**: Sync, async, stream, and fire-and-forget

## Installation

Note: Require Elixir ~> 1.18 and OTP ~> 27

The package can be installed
by adding `phoenix_gen_api` to your list of dependencies in `mix.exs`:

```Elixir
def deps do
  [
    {:phoenix_gen_api, "~> 2.1"}
  ]
end
```

Note: You can use [`:libcluster`](https://hex.pm/packages/libcluster) to build a Elixir cluster.

## Usage

### Remote Node (optional)

Add config to your `config.exs` file to mark this is remote node.

```Elixir
config :phoenix_gen_api, :client_mode, true
```

Declare a module for support PhoenixGenApi can pull config.

Example:

```Elixir
defmodule MyApp.GenApi.Supporter do

  alias PhoenixGenApi.Structs.FunConfig

  @doc """
  Support for remote pull general api config.
  """
  def get_config(_arg) do
    {:ok, my_fun_configs()}
  end

  @doc """
  Return list of %FunConfig{}.
  """
  def my_fun_configs() do
    [
      %FunConfig{
        request_type: "get_data",
        service: "my_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyApp.Interface.Api, :get_data, []},
        arg_types: %{"id" => :string},
        response_type: :async,
        version: "1.0.0"
      }
    ]
  end
end
```

Note: You can add directly in runtime in gateway node without using client mode.

### Phoenix Node (Gateway node)

Add config for Phoenix can pull config from remote nodes(above) like:

```Elixir
# Config for general api.
config :phoenix_gen_api, :gen_api,
  service_configs: [
    # service config for pulling general api config.
    %{
      # service type
      service: "my_service",
      # nodes of service in cluster, need to connecto to get config
      # list of nodes or using MFA like: {ClusterHelper, get_nodes, [:my_api]}
      nodes: [:"remote_service@test.local"], 
      # module to get config
      module: MyApp.GenApi.Supporter,
      # function to get config
      function: :get_config,
      # args to get config, using for identity or check security.
      args: [:gateway_1],
    }
  ]

# Config for rate limiter.
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
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

In Phoenix Channel you can add a lit of bit code like:

```Elixir
@impl true
def handle_in("phoenix_gen_api", payload, socket) do
  result =
    payload
    |> Map.put("user_id", socket.assigns.user_id) # avoid security issue.
    |> PhoenixGenApi.Executor.execute_params()

    case result do
      result = %Response{} ->

      # not a final result for async/stream call.
      push(socket, "gen_api_result", result)

    # request type is :none, no response.
    {:ok, :none} ->
      :ok
    end

  {:noreply, socket}
end

@impl true
def handle_info({:push, result}, socket) do
  push(socket, "phoenix_gen_api_result", result)

  {:noreply, socket}
end

def handle_info({:async_call, result = %Response{}}, socket) do
  push(socket, "phoenix_gen_api_result", result)

  {:noreply, socket}
end

# For receiving data from stream.
def handle_info({:stream_response, result}, socket) do
  push(socket, "gen_api_result", result)

  {:noreply, socket}
end
```

In this case, if need you can authenticate by using Phoenix framework.

Now you can start your cluster and test!

After start Phoenix app, PhoenixGenApi will auto pull config from remote node to serve client.

For test in Elixir you can use  [`phoenix_client`](https://hex.pm/packages/phoenix_client) to create a connection to Phoenix Channel.

You can push a event with content like:

```json
{
  "user_id": "user_1",
  "device_id": "device_1",
  "service": "my_service",
  "request_type": "get_data",
  "request_id": "test_request_1",
  "version": "1.0.0",
  "args": {
    "id": "test_data_id"
  }
}
```

Result like:

If is async/stream call you will receive a message like this:

```json
{
  "async": true,
  "error": "",
  "has_more": false,
  "request_id": "test_request_1",
  "result": null,
  "success": true
}
```

After that is a another message with result:

```json
{
  "async": false,
  "error": "",
  "has_more": false,
  "request_id": "test_request_1",
  "result": [
    {
      "id": "14e99227-512a-47b6-b6b1-2d4bc29ca13e",
      "name": "Hello World!"
    }
  ]
}
```

For better security you can overwrite user_id in server, using basic check permission or passing request info (user_id, device_id, request_id).

## Function Versioning

PhoenixGenApi supports multiple versions of the same API, allowing you to manage API evolution and deprecation gracefully.

### Version Configuration

Each `FunConfig` can have a `version` field (defaults to `"0.0.0"` if not specified):

```elixir
%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "1.0.0",
  nodes: :local,
  mfa: {MyApp.Users, :get_user_v1, []},
  arg_types: %{"id" => :string},
  response_type: :sync
}

%FunConfig{
  request_type: "get_user",
  service: "user_service",
  version: "2.0.0",
  nodes: :local,
  mfa: {MyApp.Users, :get_user_v2, []},
  arg_types: %{"id" => :string, "fields" => :list_string},
  response_type: :sync
}
```

### Request Version

Clients can specify which version they want to use by including the `version` field in their request:

```json
{
  "user_id": "user_1",
  "service": "user_service",
  "request_type": "get_user",
  "request_id": "req_1",
  "version": "2.0.0",
  "args": {
    "id": "123",
    "fields": ["name", "email"]
  }
}
```

If no version is specified, the system defaults to `"0.0.0"`.

### Managing Versions

You can manage API versions programmatically:

```elixir
alias PhoenixGenApi.ConfigDb

# Get a specific version
{:ok, config} = ConfigDb.get("user_service", "get_user", "1.0.0")

# Get the latest enabled version
{:ok, latest_config} = ConfigDb.get_latest("user_service", "get_user")

# Disable a version (e.g., for deprecation)
:ok = ConfigDb.disable("user_service", "get_user", "1.0.0")

# Re-enable a disabled version
:ok = ConfigDb.enable("user_service", "get_user", "1.0.0")

# Delete a specific version
:ok = ConfigDb.delete("user_service", "get_user", "1.0.0")

# List all functions with their versions
%{
  "user_service" => %{
    "get_user" => ["1.0.0", "2.0.0"],
    "create_user" => ["1.0.0"]
  }
} = ConfigDb.get_all_functions()
```

### Version Behavior

- **Disabled versions** return `{:error, :disabled}` when accessed
- **Non-existent versions** return `{:error, :not_found}`
- **Multiple versions** can coexist independently
- **Disabling one version** does not affect other versions
- **`get_latest/2`** returns the highest version number that is enabled

## Rate Limiter

PhoenixGenApi includes a high-performance sliding window rate limiter using ETS for tracking.

### Configuration

Configure rate limits in `config.exs`:

```elixir
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  global_limits: [
    # 2000 requests per minute per user
    %{key: :user_id, max_requests: 2000, window_ms: 60_000},
    # 10000 requests per minute per device
    %{key: :device_id, max_requests: 10000, window_ms: 60_000}
  ],
  api_limits: [
    # Expensive operation: 10 requests per minute
    %{
      service: "data_service",
      request_type: "export_data",
      key: :user_id,
      max_requests: 10,
      window_ms: 60_000
    },
    # Public endpoint: 100 requests per minute
    %{
      service: "public_service",
      request_type: "search",
      key: :ip_address,
      max_requests: 100,
      window_ms: 60_000
    }
  ]
```

### Usage

Rate limiting is automatically checked when you call `Executor.execute!/1` or `Executor.execute_params!/1`.

You can also check rate limits manually:

```elixir
alias PhoenixGenApi.RateLimiter

# Check rate limit for a request
case RateLimiter.check_rate_limit(request) do
  :ok ->
    # Proceed with execution
    Executor.execute!(request)

  {:error, :rate_limited, details} ->
    # Return rate limit error
    %{
      error: "Rate limit exceeded",
      retry_after: details.retry_after_ms,
      current_requests: details.current_requests,
      max_requests: details.max_requests
    }
end

# Check global rate limit directly
RateLimiter.check_rate_limit("user_123", :global, :user_id)

# Check API-specific rate limit
RateLimiter.check_rate_limit("user_123", {"my_service", "my_api"}, :user_id)
```

### Dynamic Configuration

Update rate limits at runtime:

```elixir
# Add a new global limit
RateLimiter.add_global_limit(%{
  key: :ip_address,
  max_requests: 5000,
  window_ms: 60_000
})

# Update configuration
RateLimiter.update_config(%{
  enabled: true,
  global_limits: [...],
  api_limits: [...]
})
```

### Rate Limit Keys

Supported key types:
- `:user_id` - Rate limit by user
- `:device_id` - Rate limit by device
- `:ip_address` - Rate limit by IP address
- Custom string keys

### Telemetry

The rate limiter emits telemetry events for monitoring:

```elixir
:telemetry.attach(
  "rate-limiter-monitor",
  [:phoenix_gen_api, :rate_limiter, :exceeded],
  fn event, measurements, metadata, config ->
    Logger.warning("Rate limit exceeded: #{inspect(metadata)}")
  end,
  %{}
)
```

## Permission System

PhoenixGenApi provides a flexible permission system with multiple modes for authentication and authorization.

### Permission Modes

Configure permissions in `FunConfig.check_permission`:

#### 1. Disabled (`false`)
No permission check. Useful for public endpoints.

```elixir
%FunConfig{
  request_type: "get_public_data",
  check_permission: false
}
```

#### 2. Any Authenticated (`:any_authenticated`)
Requires a valid `user_id`. Any authenticated user can access.

```elixir
%FunConfig{
  request_type: "get_profile",
  check_permission: :any_authenticated
}

# Passes - user is authenticated
request = %Request{user_id: "user_123"}

# Fails - no user_id
request = %Request{user_id: nil}
```

#### 3. Argument-Based (`{:arg, arg_name}`)
User can only access their own data. The specified argument must match `user_id`.

```elixir
%FunConfig{
  request_type: "get_user_profile",
  check_permission: {:arg, "user_id"}
}

# Passes - user accessing their own data
request = %Request{
  user_id: "user_123",
  args: %{"user_id" => "user_123"}
}

# Fails - user trying to access another user's data
request = %Request{
  user_id: "user_123",
  args: %{"user_id" => "user_999"}
}
```

#### 4. Role-Based (`{:role, allowed_roles}`)
User must have one of the specified roles.

```elixir
%FunConfig{
  request_type: "delete_user",
  check_permission: {:role, ["admin", "moderator"]}
}

# Passes - user has admin role
request = %Request{
  user_id: "user_123",
  user_roles: ["admin"]
}

# Passes - user has moderator role
request = %Request{
  user_id: "user_456",
  user_roles: ["moderator", "user"]
}

# Fails - user doesn't have required role
request = %Request{
  user_id: "user_789",
  user_roles: ["user"]
}
```

### Request Structure for Permissions

```elixir
%Request{
  user_id: "user_123",           # Required for permission checks
  user_roles: ["admin", "user"], # Required for role-based checks
  request_type: "get_profile",
  service: "user_service",
  request_id: "req_1",
  args: %{"user_id" => "user_123"}
}
```

### Security Best Practices

- Always use specific permission modes rather than `false` when possible
- Use `{:arg, "user_id"}` to ensure users can only access their own data
- Use `{:role, [...]}` for admin-only endpoints
- Missing arguments result in permission denial
- All permission failures are logged for audit purposes
- Permission checks happen before argument validation and function execution

## Full Example

We will add a full example in the future.

## Planned Features

- [DONE] Add pool processes for save/limit resource.
- [DONE] Function versioning with enable/disable support.
- [DONE] Rate limiter with sliding window algorithm.
- Sticky node.

## Support AI agents & MCP for dev & improvement

Run this command for update guide & rules from deps to repo for supporting ai agents.

```bash
mix usage_rules.sync AGENTS.md --all \
  --link-to-folder deps \
  --inline usage_rules:all
```

Run this command for enable MCP server

```bash
mix tidewave
```

Config MCP for agent `http://localhost:4114/tidewave/mcp`, changes port in `mix.exs` file if needed. Go to [Tidewave](https://hexdocs.pm/tidewave/) for more informations.