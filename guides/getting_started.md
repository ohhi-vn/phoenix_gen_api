# Getting Started

Build a working API in 5 minutes — starting with a **single node**. You will see results in your browser in Phase 1, then split the node into a proper **gateway + service** cluster in Phase 2.

## What You'll Build

Phase 1 — one node does everything:

```text
+--------------+     WebSocket     +---------------------------+
|   Browser    | <---------------> |  Your Phoenix app         |
|   Client     |   Phoenix Channel |  (gateway + service, solo)|
+--------------+                   +---------------------------+
```

Phase 2 — the same app split into two connected nodes:

```text
+--------------+     WebSocket     +----------------+     RPC     +----------------+
|   Browser    | <---------------> | Gateway node   | <---------> | Service node   |
|   Client     |   Phoenix Channel | (Phoenix app)  |   Erlang    | (your app)     |
+--------------+                   +----------------+             +----------------+
```

The client calls `"get_user"` over a Phoenix Channel. The gateway routes the request to the node that owns the function and returns the data — without writing any HTTP endpoint.

## Prerequisites

- Elixir ~> 1.18, OTP ~> 27
- Phoenix 1.8+ (`mix archive.install hex phx_new`)

---

# Phase 1 — Single Node, Working in Minutes

## Step 1 — Create the project

```bash
mix phx.new demo_api --no-ecto --no-mailer --no-gettext --no-html
cd demo_api
```

### Add the dependency

```elixir
# demo_api/mix.exs
def deps do
  [
    {:phoenix_gen_api, "~> 2.24"}
    # ... other Phoenix deps already present
  ]
end
```

```bash
mix deps.get
```

## Step 2 — Write the API function

```elixir
# demo_api/lib/demo_api/api.ex
defmodule DemoApi.Api do
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

Every endpoint returns `{:ok, result}` or `{:error, reason}` — that is the contract.

## Step 3 — Create the Channel and Socket

```elixir
# demo_api/lib/demo_api_web/channels/api_channel.ex
defmodule DemoApiWeb.ApiChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "api"

  @impl true
  def join("api:lobby", _payload, socket) do
    {:ok, socket}
  end
end
```

`use PhoenixGenApi` injects all `handle_in` and `handle_info` callbacks — incoming requests, sync results, async results, stream chunks, and relay messages.

```elixir
# demo_api/lib/demo_api_web/channels/user_socket.ex
defmodule DemoApiWeb.UserSocket do
  use Phoenix.Socket

  channel "api:lobby", DemoApiWeb.ApiChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case params["user_id"] do
      user_id when is_binary(user_id) and byte_size(user_id) > 0 ->
        {:ok, assign(socket, :user_id, user_id)}

      _ ->
        :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
```

> **Why the `user_id` check?** By default PhoenixGenApi rejects requests from sockets without a verified `user_id` (option `require_verified_user_id`, default `true`). This protects your endpoints from unauthenticated calls. The JS client passes `user_id` in the socket params below.

Register the socket in the endpoint:

```elixir
# demo_api/lib/demo_api_web/endpoint.ex
  socket "/socket", DemoApiWeb.UserSocket,
    websocket: true,
    longpoll: false
```

## Step 4 — Register the endpoints

PhoenixGenApi executes functions based on a `FunConfig` struct — the "route table" of your API. For the single-node phase, register the configs directly at boot:

```elixir
# demo_api/lib/demo_api/application.ex
defmodule DemoApi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DemoApiWeb.Telemetry,
      {Phoenix.PubSub, name: DemoApi.PubSub},
      DemoApiWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: DemoApi.Supervisor]
    result = Supervisor.start_link(children, opts)

    register_api_configs()

    result
  end

  defp register_api_configs do
    alias PhoenixGenApi.Structs.FunConfig

    PhoenixGenApi.ConfigDb.add(%FunConfig{
      request_type: "list_users",
      service: "user_service",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5_000,
      mfa: {DemoApi.Api, :list_users, []},
      response_type: :sync
    })

    PhoenixGenApi.ConfigDb.add(%FunConfig{
      request_type: "get_user",
      service: "user_service",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5_000,
      mfa: {DemoApi.Api, :get_user, []},
      arg_types: %{"user_id" => :string},
      arg_orders: [],
      response_type: :sync
    })
  end

  # Tell Phoenix to update the endpoint configuration
  @impl true
  def config_change(changed, _new, removed) do
    DemoApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

Key fields (see the [FunConfig Reference](./fun_config.md) for all of them):

- `nodes: [Node.self()]` — the function lives on *this* node. (Note: prefer this over `:local`; see [Node selection](./fun_config.md#node-selection-strategies-choose_node_mode).)
- `choose_node_mode: :random`, `response_type: :sync` — required, there is no default.
- `arg_types` + `arg_orders` — when you declare argument types, also declare `arg_orders` (or `:map`).
- `mfa` — the function to call; its module is loaded lazily by the executor.

## Step 5 — Run it

```bash
mix phx.server
```

## Step 6 — Test from the browser

Create `demo_api/priv/static/demo.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <title>DemoApi</title>
</head>
<body>
  <button id="listBtn">List Users</button>
  <button id="getBtn">Get User 1</button>
  <pre id="output"></pre>

  <script src="https://cdn.jsdelivr.net/npm/phoenix@1.8/priv/static/phoenix.min.js"></script>
  <script>
    // user_id goes into the socket params — see the socket code above
    const socket = new Phoenix.Socket("ws://localhost:4000/socket", {
      params: { user_id: "demo_user" }
    });
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

Open `http://localhost:4000/demo.html`, click the buttons, and you will see the responses.

You can also test from IEx on the same node:

```elixir
alias PhoenixGenApi.Structs.Request

request = %Request{
  request_id: "test_1",
  service: "user_service",
  request_type: "get_user",
  args: %{"user_id" => "1"}
}

PhoenixGenApi.Executor.execute!(request)
# => %Response{request_id: "test_1", success: true, result: %{id: "1", name: "Alice", ...}}
```

**Phase 1 done.** Now let's split the node.

---

# Phase 2 — Split into Gateway + Service Nodes

In Phase 1, the node that serves the browser is also the node that owns the functions. In production you separate them: the **gateway** handles websocket connections, and the **service node** owns the functions. PhoenixGenApi connects them in two ways:

- **Pull** — the gateway periodically pulls the `FunConfig` list from the service node.
- **Push** — the service node pushes its configs to the gateway at startup (and on change).

This guide uses **pull** (the simplest to wire up).

## Step 7 — Create the service node

```bash
mix new my_service --sup
cd my_service
```

### Add dependencies and the supporter module

```elixir
# my_service/mix.exs
def deps do
  [
    {:phoenix_gen_api, "~> 2.24"},
    {:libcluster, "~> 3.3"}
  ]
end
```

```elixir
# my_service/lib/my_service/api.ex
defmodule MyService.Api do
  # same functions as DemoApi.Api above
end
```

The **supporter module** tells the gateway which functions this service exposes:

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
        response_type: :sync
      },
      %FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyService.Api, :get_user, []},
        arg_types: %{"user_id" => :string},
        arg_orders: [],
        response_type: :sync
      }
    ]
  end
end
```

Note: the supporter runs *on the service node*, so `Node.self()` resolves to the service node — the gateway receives the config already pointed at the right place.

### Configure the service node

```elixir
# my_service/config/config.exs
import Config

# Mark this node as a remote (client-mode) node
config :phoenix_gen_api, :client_mode, true

config :libcluster,
  topologies: [
    demo: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"gateway@127.0.0.1"]]
    ]
  ]
```

```elixir
# my_service/lib/my_service/application.ex
defmodule MyService.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: MyService.ClusterSupervisor]]}
    ]

    Supervisor.start_link(children, [strategy: :one_for_one, name: MyService.Supervisor])
  end
end
```

## Step 8 — Reconfigure the gateway

Remove the direct `register_api_configs/0` from Phase 1 and instead **pull** configs from the service node:

```elixir
# demo_api/config/config.exs
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

config :libcluster,
  topologies: [
    demo: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"my_service@127.0.0.1"]]
    ]
  ]
```

Add libcluster to the gateway's supervision tree:

```elixir
# demo_api/lib/demo_api/application.ex — add to children:
{Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: DemoApi.ClusterSupervisor]]}
```

The channel, socket, and browser client stay exactly as in Phase 1.

## Step 9 — Run the cluster

Open two terminals:

```bash
# Terminal 1 — service node
cd my_service
iex --sname my_service -S mix

# Terminal 2 — gateway node
cd demo_api
iex --sname gateway -S mix phx.server
```

Wait for the cluster to connect, then verify in the gateway's IEx:

```elixir
PhoenixGenApi.cache_status()
# === ConfigDb Cache Status ===
# Total cached configs: 2
# Services: ["user_service"]
```

Reload `demo.html` and click the buttons — same behavior, but now the functions execute on the service node via RPC.

---

# Testing

Register a config in your test and execute through the library — no HTTP, no websocket needed for the executor-level tests:

```elixir
# test/demo_api/api_test.exs
defmodule DemoApi.ApiTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  setup do
    config = %FunConfig{
      request_type: "get_user",
      service: "user_service",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5_000,
      mfa: {DemoApi.Api, :get_user, []},
      arg_types: %{"user_id" => :string},
      arg_orders: [],
      response_type: :sync
    }

    :ok = PhoenixGenApi.ConfigDb.add(config)

    request = %Request{
      request_id: "test_1",
      service: "user_service",
      request_type: "get_user",
      args: %{"user_id" => "1"}
    }

    %{request: request}
  end

  test "returns the user", %{request: request} do
    response = PhoenixGenApi.Executor.execute!(request)

    assert response.success == true
    assert response.result.name == "Alice"
  end

  test "returns an error for unknown users" do
    request = %Request{
      request_id: "test_2",
      service: "user_service",
      request_type: "get_user",
      args: %{"user_id" => "999"}
    }

    response = PhoenixGenApi.Executor.execute!(request)
    assert response.success == false
  end
end
```

> Error reasons are masked as `"Internal Server Error"` by default. Set `config :phoenix_gen_api, :detail_error, true` (in `config/test.exs`) to get `"Internal Server Error: :not_found"`-style messages in tests.

For a full channel test, use Phoenix's `ChannelCase`:

```elixir
defmodule DemoApiWeb.ApiChannelTest do
  use DemoApiWeb.ChannelCase, async: false

  alias PhoenixGenApi.Structs.Response

  setup do
    config = %FunConfig{
      request_type: "get_user",
      service: "user_service",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5_000,
      mfa: {DemoApi.Api, :get_user, []},
      arg_types: %{"user_id" => :string},
      arg_orders: [],
      response_type: :sync
    }

    :ok = PhoenixGenApi.ConfigDb.add(config)

    socket = socket(DemoApiWeb.UserSocket, "demo_user", %{user_id: "demo_user"})
    {:ok, _, socket} = subscribe_and_join(socket, DemoApiWeb.ApiChannel, "api:lobby", %{})
    %{socket: socket}
  end

  test "get_user returns the user", %{socket: socket} do
    push(socket, "api", %{
      service: "user_service",
      request_type: "get_user",
      request_id: "req_1",
      args: %{"user_id" => "1"}
    })

    assert_push "api", %Response{success: true, result: user}
    assert user.name == "Alice"
  end

  test "unauthenticated requests are rejected", %{socket: socket} do
    socket = Phoenix.Socket.assign(socket, :user_id, nil)

    push(socket, "api", %{
      service: "user_service",
      request_type: "get_user",
      request_id: "req_2"
    })

    assert_push "api", %Response{success: false, error: "Authentication required"}
  end
end
```

Note: over `ChannelCase` the payload arrives as the raw `%Response{}` struct (JSON encoding happens at the wire). Over a real websocket, the client receives the JSON object shown in the browser demo.

---

# Troubleshooting

**`"Authentication required"` on every request**
`use PhoenixGenApi` defaults to `require_verified_user_id: true` — the socket must have a non-empty `user_id` assign. Set it in `UserSocket.connect/3` (as shown above). For intentionally public endpoints, set `use PhoenixGenApi, event: "api", require_verified_user_id: false`.

**`unsupported function: <name> version latest`**
The gateway has no `FunConfig` for that `{service, request_type}` pair. Check `PhoenixGenApi.cache_status()` — is the service registered? For pull mode: is the cluster connected (`Node.list()`), and is `service_configs` correct? For push mode: did the service node push (see `PhoenixGenApi.pushed_services_status()`)?

**`FunConfig validation failed` / `add failed: invalid config`**
`choose_node_mode`, `response_type` and (when `arg_types` is set) `arg_orders` must be set explicitly — they have no defaults. See the [FunConfig Reference](./fun_config.md).

**Node not connected**
`iex --sname` names must match the configured topology hosts (`:"my_service@127.0.0.1"`). Check `epmd -names` and `Node.list()`.

---

# What's Next

- **Concepts** — [Concepts Guide](./concepts.md): the mental model in 5 minutes
- **Endpoint reference** — [FunConfig Reference](./fun_config.md): all fields, argument validation, permissions, retry, hooks, `result_encoder`
- **App config** — [Configuration](./configuration.md): pull/push wiring, rate limiter, worker pools, security
- **Feature guide** — [Relay Messages](./relay_messages.md): group-based messaging
- **Observability** — [Telemetry](./telemetry.md), [Diagnostics](./diagnostics.md)
- **Internals** — [Architecture](./architecture.md): supervision tree, request lifecycle, line-by-line execution
