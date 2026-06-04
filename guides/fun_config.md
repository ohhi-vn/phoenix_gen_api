# FunConfig Reference

`FunConfig` is the central configuration struct. Each `FunConfig` maps one `{service, request_type}` pair to one function call.

## Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `request_type` | `String.t()` | **required** | API endpoint name (e.g. `"get_user"`) |
| `service` | `atom \| String.t()` | **required** | Service group name (e.g. `"user_service"`) |
| `nodes` | `[atom] \| {m,f,a} \| :local` | **required** | Target nodes or `:local` for same-node execution |
| `choose_node_mode` | `atom` | `:random` | Node selection strategy (see below) |
| `timeout` | `integer \| :infinity` | **required** | Execution timeout in ms (100–300_000 or `:infinity`) |
| `mfa` | `{module, function, args}` | **required** | The function to call |
| `arg_types` | `map() \| nil` | `nil` | Argument type declarations for validation |
| `arg_orders` | `[String.t()] \| :map` | `[]` | Argument ordering (or `:map` to pass a map) |
| `response_type` | `atom` | `:sync` | `:sync` \| `:async` \| `:stream` \| `:none` |
| `check_permission` | `atom \| tuple` | `false` | Permission mode (see below) |
| `permission_callback` | `{m,f,a} \| nil` | `nil` | Custom permission check MFA |
| `version` | `String.t() \| nil` | `nil` | API version. `"0.0.0"` is reserved as a sentinel |
| `disabled` | `boolean` | `false` | Soft-delete flag |
| `retry` | `nil \| number \| tuple` | `nil` | Retry configuration |
| `before_execute` | `tuple \| nil` | `nil` | Hook called before execution |
| `after_execute` | `tuple \| nil` | `nil` | Hook called after execution |
| `hook_timeout` | `pos_integer()` | `5_000` | Per-hook timeout in ms |
| `request_info` | `boolean` | `false` | Legacy field, currently unused in execution |

## Node Selection Strategies (`choose_node_mode`)

| Strategy | Value | Description |
|----------|-------|-------------|
| Random | `:random` | Pick a random node |
| Hash (request_id) | `:hash` | Hash the `request_id` to pick a node |
| Hash (arg value) | `{:hash, "user_id"}` | Hash the value of the named arg |
| Round-robin | `:round_robin` | Cycle through nodes in order |
| Sticky | `{:sticky, "user_id"}` | Same key value always maps to the same node (persisted via ETS) |

## Permission Modes (`check_permission`)

| Mode | Value | Description |
|------|-------|-------------|
| Disabled | `false` | No permission check (default) |
| Any authenticated | `:any_authenticated` | Requires `user_id` to be non-nil |
| Arg-based | `{:arg, "user_id"}` | Compares `user_id` from socket to the named arg value |
| Role-based | `{:role, ["admin"]}` | Checks if any user role is in the allowed list |

When `permission_callback` is set to an MFA tuple, it **overrides** `check_permission` entirely.

## Response Types (`response_type`)

| Type | Description |
|------|-------------|
| `:sync` | Execute and return the result immediately |
| `:async` | Acknowledge immediately, send result later via `{:async_call, result}` |
| `:stream` | Start a `StreamCall` GenServer that sends chunks via `{:stream_response, result}` |
| `:none` | Fire-and-forget; no response sent to the client |

## Retry Configuration (`retry`)

| Value | Description |
|-------|-------------|
| `nil` | No retry (default) |
| `3` | Equivalent to `{:all_nodes, 3}` |
| `{:same_node, 2}` | Retry on the originally selected node(s) |
| `{:all_nodes, 3}` | Retry across all available nodes |

For `nodes: :local`, both `:same_node` and `:all_nodes` retry locally.

## Argument Types (`arg_types`)

### Simple format

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

## Version

The `version` field is a string (e.g., `"1.0.0"`). The value `"0.0.0"` is reserved as a sentinel and cannot be explicitly registered — it is used internally to mean "no version specified". If a config has no version set, it is stored with a `nil` version key in the cache.

## Validation

Use `FunConfig.valid?/1` for a quick boolean check or `FunConfig.validate_with_details/1` for detailed error messages:

```elixir
case FunConfig.validate_with_details(config) do
  {:ok, _} -> :valid
  {:error, errors} -> IO.inspect(errors)
end
```

Validation checks include: `request_type` is non-empty, `service` is not nil, `nodes` is valid, `choose_node_mode` is recognized, `timeout` is within bounds, `mfa` is a valid tuple, `arg_types` and `arg_orders` are consistent, `response_type` is valid, `check_permission` is valid, `retry` is valid, hooks are valid MFAs, `hook_timeout` is positive.

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

- **[Step-by-Step Guide](./step_by_step_guide.md)** — Code examples for using each FunConfig field.
- **[Configuration](./configuration.md)** — Application-level configuration reference.
- **[Architecture](./architecture.md)** — How FunConfig fits into the system architecture.
