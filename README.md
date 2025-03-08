[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/phoenix_gen_api)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_gen_api.svg?style=flat&color=blue)](https://hex.pm/packages/phoenix_gen_api)

# PhoenixGenApi

The library helps quickly develop APIs based on Phoenix Channel.
Helps developers add and update APIs at runtime from other nodes in the cluster without restarting or reconfiguring the Phoenix app.
In this case, the Phoenix app will take on the role of an API gateway.
APIs can be added dynamically at runtime without needing to reconfigure.

## Concept

After received an event from client(in handle_in callback of Phoenix Channel) Phoenix Channel process will pass data to PhoenixGenApi to find final event & target node to execute then get result & push to response to client.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phoenix_gen_api` to your list of dependencies in `mix.exs`:

```Elixir
def deps do
  [
    {:phoenix_gen_api, "~> 0.0.5"}
  ]
end
```

We has two step to add PhoenixGenApi to our system.

Note: You can use [`:libcluster`](https://hex.pm/packages/libcluster) to build a Elixir cluster.

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
  def get_config() do
    {:ok, my_fun_configs()}
  end

  @doc """
  Return list of %FunConfig{}.
  """
  def my_fun_configs() do
    [
      %FunConfig{
        request_type: "get_data",
        service: :club_service,
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {MyApp.Interface.Api, :get_data, []},
        arg_types: %{"id" => :string},
        response_type: :async
      }
    ]
  end
end
```

Note: You can add directly in runtime in Phoenix app node without using client mode.

### Phoenix Node (Gateway node)

Add config for Phoenix can pull config from remote nodes(above) like:

```Elixir
# Config for general api, lib made by team.
config :phoenix_gen_api, :gen_api,
  service_configs: [
    # service config for pulling general api config.
    %{
      # service type
      service: :remote_service,
      # nodes of service in cluster, need to connecto to get config
      nodes: [:"remote_service@test.local"],
      # module to get config
      module: MyApp.GenApi.Supporter,
      # function to get config
      function: :get_config,
      # args to get config, using for identity or check security.
      args: [:gateway_1],
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

  # not a final result for async/stream call.
  push(socket, "phoenix_gen_api_result", result)

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
```

Now you can start your cluster and test!

After start Phoenix app, PhoenixGenApi will auto pull config from remote node to serve client.

For test in Elixir you can use  [`phoenix_client`](https://hex.pm/packages/phoenix_client) to create a connecto to Phoenix Channel.

You can push a event with content like:

```json
{
  "user_id": "user_1",
  "device_id": "device_1",
  "request_type": "get_data",
  "request_id": "test_request_1",
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

For better security you can overwrite user_id in server.

### Full Example

We will add a full example in the future.
