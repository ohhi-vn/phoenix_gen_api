# Getting Started

Build a working API gateway in 10 minutes. This guide walks you through a minimal but complete setup with two nodes: a **Phoenix gateway** and a **service node**.

## What You'll Build

```text
┌────────────┐     WebSocket      ┌─────────────────┐     RPC      ┌──────────────┐
│  Browser   │ ◄──────────────► │  Gateway Node    │ ◄──────────► │ Service Node │
│  Client    │   Phoenix Ch.    │  (Phoenix app)   │   Erlang     │  (your app)  │
└────────────┘                   └─────────────────┘              └──────────────┘
                                 port 4000                        port 4001
```

The client calls `"list_users"` over a Phoenix Channel. The gateway forwards the request to the service node, which returns data — all without writing any HTTP endpoints.

## Prerequisites

- Elixir ~> 1.18, OTP ~> 27
- Two connected Erlang nodes (we'll use `libcluster`)

---

## Step 1 — Create the Service Node

Create a new Elixir project:

```bash
mix new my_service --sup
cd my_service
```

### Add dependencies

```elixir
# my_service/mix.exs
def deps do
  [
    {:phoenix_gen_api, "~> 2.10"},
    {:libcluster, "~> 3.3"}
  ]
end
```

```bash
mix deps.get
```

### Write the API function

```elixir
# my_service/lib/my_service/api.ex
defmodule MyService.Api do
  @users [
    %{id: "1", name: "Alice", email: "alice@example.com"},
    %{id: "2", name: "Bob", email: "bob@example.com"},
    %{id: "3", name: "Charlie", email: "charlie@example.com"}
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

### Create the supporter module

This module tells the gateway which functions are available:

```elixir
# my_service/lib/my_service/gen_api/supporter.ex
defmodule MyService.GenApi.Supporter do
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
        mfa: {MyService.Api, :list_users, []},
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
        mfa: {MyService.Api, :get_user, []},
        arg_types: %{"user_id" => :string},
        response_type: :sync,
        version: "1.0.0"
      }
    ]
  end
end
```

### Configure the service node

```elixir
# my_service/config/config.exs
import Config

config :my_service, MyService.Repo, []

# Mark this node as a remote (client-mode) node
config :phoenix_gen_api, :client_mode, true

# Cluster config — connect to the gateway
config :libcluster,
  topologies: [
    example: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"gateway@127.0.0.1"]]
    ]
  ]
```

### Add libcluster to the supervision tree

```elixir
# my_service/lib/my_service/application.ex
defmodule MyService.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: MyService.ClusterSupervisor]]}
    ]

    opts = [strategy: :one_for_one, name: MyService.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Step 2 — Create the Gateway Node

Create a Phoenix project:

```bash
mix phx.new my_gateway --no-ecto --no-mailer --no-gettext --no-html
cd my_gateway
```

### Add dependencies

```elixir
# my_gateway/mix.exs
def deps do
  [
    {:phoenix_gen_api, "~> 2.10"},
    {:libcluster, "~> 3.3"}
    # ... other Phoenix deps already present
  ]
end
```

```bash
mix deps.get
```

### Create the API Channel

```elixir
# my_gateway/lib/my_gateway_web/channels/api_channel.ex
defmodule MyGatewayWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"

  def join("api:lobby", _payload, socket) do
    {:ok, socket}
  end
end
```

That's it — `use PhoenixGenApi` injects all the `handle_in` and `handle_info` callbacks.

### Register the channel in the socket

```elixir
# my_gateway/lib/my_gateway_web/channels/user_socket.ex
defmodule MyGatewayWeb.UserSocket do
  use Phoenix.Socket

  channel "api:lobby", MyGatewayWeb.ApiChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
```

### Configure the gateway

```elixir
# my_gateway/config/config.exs
import Config

# ... existing Phoenix config ...

# PhoenixGenApi — pull config from the service node
config :phoenix_gen_api, :gen_api,
  pull_timeout: 5_000,
  pull_interval: 30_000,
  service_configs: [
    %{
      service: "user_service",
      nodes: [:"my_service@127.0.0.1"],
      module: MyService.GenApi.Supporter,
      function: :get_config,
      args: []
    }
  ]

# Rate limiter (optional)
config :phoenix_gen_api, :rate_limiter,
  enabled: true,
  global_limits: [
    %{key: :user_id, max_requests: 1000, window_ms: 60_000}
  ]

# Cluster config — connect to the service node
config :libcluster,
  topologies: [
    example: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"my_service@127.0.0.1"]]
    ]
  ]
```

### Add libcluster to the supervision tree

```elixir
# my_gateway/lib/my_gateway/application.ex
defmodule MyGateway.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ... existing children ...
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: MyGateway.ClusterSupervisor]]}
    ]

    opts = [strategy: :one_for_one, name: MyGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Step 3 — Run It

Open two terminals.

### Terminal 1 — Start the service node

```bash
cd my_service
iex --sname my_service@127.0.0.1 -S mix
```

### Terminal 2 — Start the gateway

```bash
cd my_gateway
iex --sname gateway@127.0.0.1 -S mix phx.server
```

Wait a moment for the cluster to connect. The gateway will automatically pull the `FunConfig` from the service node.

Verify in the gateway's IEx:

```elixir
iex(gateway@127.0.0.1)1> PhoenixGenApi.cache_status()
# You should see "user_service" registered
```

---

## Step 4 — Test with a JavaScript Client

Add Phoenix's JS client to an HTML page:

```html
<!DOCTYPE html>
<html>
<head>
  <title>PhoenixGenApi Demo</title>
</head>
<body>
  <h1>PhoenixGenApi Demo</h1>
  <button id="listBtn">List Users</button>
  <button id="getBtn">Get User 1</button>
  <pre id="output"></pre>

  <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7/build/phoenix.min.js"></script>
  <script>
    const socket = new Phoenix.Socket("ws://localhost:4000/socket", {});
    socket.connect();

    const channel = socket.channel("api:lobby", {});
    const output = document.getElementById("output");

    channel.on("api", payload => {
      output.textContent = JSON.stringify(payload, null, 2);
    });

    channel.join()
      .receive("ok", () => console.log("Joined!"))
      .receive("error", reason => console.log("Failed:", reason));

    document.getElementById("listBtn").addEventListener("click", () => {
      channel.push("api", {
        service: "user_service",
        request_type: "list_users",
        request_id: "req_" + Date.now()
      });
    });

    document.getElementById("getBtn").addEventListener("click", () => {
      channel.push("api", {
        service: "user_service",
        request_type: "get_user",
        request_id: "req_" + Date.now(),
        args: { user_id: "1" }
      });
    });
  </script>
</body>
</html>
```

Open this file in a browser, click the buttons, and you'll see the responses.

---

## Step 5 — Test in IEx

You can also test directly from the gateway's IEx:

```elixir
alias PhoenixGenApi.Structs.Request

# List users
request = %Request{
  request_id: "test_1",
  service: "user_service",
  request_type: "list_users",
  args: %{}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_1", success: true, result: [%{id: "1", name: "Alice", ...}, ...]}

# Get a single user
request = %Request{
  request_id: "test_2",
  service: "user_service",
  request_type: "get_user",
  args: %{"user_id" => "1"}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_2", success: true, result: %{id: "1", name: "Alice", ...}}
```

---

## What's Happening

1. The **service node** defines `MyService.GenApi.Supporter` which returns a list of `FunConfig` structs.
2. The **gateway** is configured to pull from that supporter on startup (and every 30 s after).
3. When a client sends `{service: "user_service", request_type: "list_users"}`, the gateway:
   - Looks up the matching `FunConfig`
   - Selects a node (`:random` in this case)
   - Validates arguments (none for `list_users`, `"user_id"` for `get_user`)
   - Calls the MFA remotely via RPC
   - Returns the result to the client

---

## Next Steps

- **Add permissions** — set `check_permission: :any_authenticated` on your `FunConfig` and pass `user_id` from the socket
- **Add rate limiting** — configure `api_limits` for expensive endpoints
- **Use async/stream** — set `response_type: :async` or `:stream` for long-running operations
- **Push instead of pull** — use `ConfigPusher.push_on_startup/2` for immediate registration
- **Version your APIs** — add multiple `FunConfig` entries with different `version` strings
- **Monitor with telemetry** — attach handlers to track request duration, errors, and rate limits
- **Sticky node affinity** — use `{:sticky, "user_id"}` in `choose_node_mode` to always route the same user to the same node

### Sticky Node Affinity Example

For stateful services where a user's requests should consistently go to the same node:

```elixir
config = %FunConfig{
  request_type: "get_profile",
  service: "user_service",
  nodes: [:"node1@host", :"node2@host"],
  choose_node_mode: {:sticky, "user_id"},
  mfa: {MyApp.Api, :get_profile, []},
  arg_types: %{"user_id" => :string},
  response_type: :sync
}
```

The first time `user_123` makes a request, a node is randomly selected and "stuck" for that user.
Subsequent requests from `user_123` will go to the same node (for up to 1 hour, after which it may re-select).

## Step 6 — Add Relay Messages

Enable group-based chat where all members receive each other's messages.

### Add the relay FunConfig

```elixir
# In your gateway's config or supporter module
alias PhoenixGenApi.Structs.FunConfig

relay_config = %FunConfig{
  request_type: "send_message",
  service: "chat_service",
  nodes: :local,
  mfa: {PhoenixGenApi.Relay, :handle_relay, []},
  arg_types: %{"group_id" => :string, "message" => :string},
  arg_orders: ["group_id", "message"],
  response_type: :sync,
  check_permission: :any_authenticated
}

PhoenixGenApi.ConfigDb.add(relay_config)
```

### Create a chat channel

```elixir
# my_gateway/lib/my_gateway_web/channels/chat_channel.ex
defmodule MyGatewayWeb.ChatChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "chat"

  def join("chat:" <> group_id, _payload, socket) do
    # Auto-join the relay group when joining the channel
    PhoenixGenApi.Relay.join_group(group_id, socket.assigns.user_id, self())
    {:ok, socket}
  end

  def handle_info({:relay_message, response}, socket) do
    push(socket, "chat", response.result)
    {:noreply, socket}
  end
end
```

### Test in IEx

```elixir
# Create a group
PhoenixGenApi.Relay.create_group("room_1", :public, "admin", some_pid)

# Send a relay message
alias PhoenixGenApi.Structs.Request

request = %Request{
  request_id: "msg_1",
  service: "chat_service",
  request_type: "send_message",
  user_id: "admin",
  args: %{"group_id" => "room_1", "message" => "Hello!"}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{success: true, result: %{"status" => "relayed", "recipients_count" => 1}}
```

See the [Relay Messages Guide](./relay_messages.md) for the full reference including group types (`:public`, `:private`, `:strict_private`), mute/unmute, and the permission matrix.

---

## Next Steps

- **Add permissions** — set `check_permission: :any_authenticated` on your `FunConfig` and pass `user_id` from the socket
- **Add rate limiting** — configure `api_limits` for expensive endpoints
- **Use async/stream** — set `response_type: :async` or `:stream` for long-running operations
- **Push instead of pull** — use `ConfigPusher.push_on_startup/2` for immediate registration
- **Version your APIs** — add multiple `FunConfig` entries with different `version` strings
- **Monitor with telemetry** — attach handlers to track request duration, errors, and rate limits
- **Sticky node affinity** — use `{:sticky, "user_id"}` in `choose_node_mode` to always route the same user to the same node
- **Relay messages** — see the [Relay Messages Guide](./relay_messages.md) for group-based messaging

### Sticky Node Affinity Example

For stateful services where a user's requests should consistently go to the same node:

```elixir
config = %FunConfig{
  request_type: "get_profile",
  service: "user_service",
  nodes: [:"node1@host", :"node2@host"],
  choose_node_mode: {:sticky, "user_id"},
  mfa: {MyApp.Api, :get_profile, []},
  arg_types: %{"user_id" => :string},
  response_type: :sync
}
```

The first time `user_123` makes a request, a node is randomly selected and "stuck" for that user.
Subsequent requests from `user_123` will go to the same node (for up to 1 hour, after which it may re-select).

See the [README](../README.md) for the full feature reference and the [Telemetry Guide](./telemetry.md) for observability.