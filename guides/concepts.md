# Concepts

The five-minute mental model of PhoenixGenApi. Every term you will meet in the guides, one diagram each.

## Gateway node vs service node

```text
  CLIENT                    GATEWAY                  SERVICE
(browser, app)          (Phoenix app)            (any Elixir app)
     |                       |                        |
     |--- websocket -------->|                        |
     |    "get_user"         |--- RPC --------------->|
     |                       |    {MyApi, :get_user}  |
     |<-- response --------- |<-- {:ok, user} --------|
```

The **gateway** accepts client connections over Phoenix Channels and routes each request to a node that can execute it. The **service node** owns the actual Elixir functions. They can be the same node (see the [Getting Started](./getting_started.md) Phase 1) or different nodes in one Erlang cluster.

## FunConfig — the endpoint declaration

```text
%FunConfig{
  request_type:    "get_user",          # the "route"
  service:         "user_service",      # the routing group
  nodes:           [Node.self()],       # which nodes can run it
  choose_node_mode: :random,            # how to pick one
  timeout:         5_000,               # execution timeout (ms)
  mfa:             {MyApi, :get_user, []},  # what to call
  arg_types:       %{"user_id" => :string},
  arg_orders:      [],                  # required when arg_types is set
  response_type:   :sync                # :sync | :async | :stream | :none
}
```

A `FunConfig` is one API endpoint: what it is called, which service it belongs to, where it runs, what to invoke, how to validate arguments, and how the response is delivered. It is the central structure — see the [FunConfig Reference](./fun_config.md) for every field.

## Supporter module — the service's inventory

```text
service node                    gateway
  Supporter.get_config() ---- pull / push ----> ConfigDb (ETS cache)
      |                                             |
      |  [%FunConfig{...}, %FunConfig{}]            |  lookup:
      |  list of FunConfig                          |  ConfigDb.get(service,
      |                                             |    request_type, version)
```

The **supporter module** is a function on the service node that returns the list of `FunConfig` it exposes. The gateway learns about endpoints from it — either by **pulling** (gateway calls the supporter every `pull_interval`), or by the service node **pushing** configs. Both models are described in the [Configuration guide](./configuration.md).

## ConfigDb — the route cache

The gateway stores all received configs in an ETS table (`PhoenixGenApi.ConfigDb`). Request routing reads directly from ETS — no GenServer call in the hot path. The cache is keyed by `{service, request_type, version}`.

## Request and Response

```text
%Request{                    %Response{
  request_id:  "req_1",        request_id:  "req_1",
  service:     "user_service", success:    true,
  request_type:"get_user",     result:      %{...},   # or
  args:        %{...},         error:       "..." ,
  user_id:     "user_1",       async:       false,
  version:     nil             has_more:    false,
}                              can_retry:   false
                             }
```

The client sends a `Request` (as JSON over the channel event). The gateway decodes it, routes it, executes the MFA, and pushes back a `Response`. The client correlates responses to requests via `request_id`.

## Node selection

When several nodes of a service can run the same endpoint, `choose_node_mode` decides which one executes the request:

```text
:random        - any node
:hash          - hash of something stable
{:hash, key}   - hash of a request arg / user_id
:round_robin   - cycle through nodes
{:sticky, key} - same key -> same node (sticky sessions)
```

Details and behavior in the [FunConfig Reference](./fun_config.md#node-selection-strategies-choose_node_mode).

## Where to go next

- [Getting Started](./getting_started.md) — build it
- [FunConfig Reference](./fun_config.md) — configure endpoints
- [Configuration](./configuration.md) — pull/push wiring and app-level options
- [Architecture](./architecture.md) — how it all works inside
