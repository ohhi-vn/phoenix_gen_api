# Diagnostics & Runtime Monitoring Guide

PhoenixGenApi provides a comprehensive diagnostics module (`PhoenixGenApi.Diagnostics`) for monitoring, debugging, and tracing the system at runtime. This guide covers all available tools.

## Table of Contents

1. [Failed Config Tracking](#failed-config-tracking)
2. [IEx Helpers](#iex-helpers)
3. [Health Checks](#health-checks)
4. [Statistics](#statistics)
5. [Debug Reports](#debug-reports)
6. [Call Flow Inspection](#call-flow-inspection)
7. [Cluster View](#cluster-view)
8. [Request Inspection](#request-inspection)
9. [Listing All Call Flows](#listing-all-call-flows)
10. [Tracing](#tracing) (admin-gated process tracing)
11. [Request Tracing](#request-tracing) (per request-type / user-id tracing)
12. [Integration Patterns](#integration-patterns)

---

## Failed Config Tracking

PhoenixGenApi automatically tracks FunConfig entries that fail validation during
pull or push. Entries are stored in an ETS table (`:phoenix_gen_api_config_failed`)
with a 24-hour TTL and include the config, failure reason, source, and originating node.

### How It Works

When a `FunConfig` fails validation at any of these points, it is recorded:

- **Pull path**: `ConfigDb.add/1`, `ConfigDb.batch_add/1`, `ConfigPuller.process_fun_list/4`
- **Push path**: `ConfigReceiver.prepare_fun_configs/1`

Each failure records:

| Field | Description |
|-------|-------------|
| `:id` | Unique monotonically increasing integer |
| `:service` | Service name |
|:request_type` | Request type |
|:version` | Version string (or nil) |
|:source` | `:pull` or `:push` |
|:node` | Originating node (or nil) |
|:reason` | List of error strings |
|:config` | The original config as a map |
|:inserted_at_ms` | Timestamp when recorded |
|:expires_at_ms` | Timestamp when entry expires (24h) |

### Querying Failed Entries

```elixir
# List all failed entries (newest first, limit 100)
PhoenixGenApi.ConfigFailed.list()

# Filter by source
PhoenixGenApi.ConfigFailed.list(source: :pull)
PhoenixGenApi.ConfigFailed.list(source: :push)

# Filter by service
PhoenixGenApi.ConfigFailed.list(service: "my_service")

# Limit results
PhoenixGenApi.ConfigFailed.list(limit: 10)

# Oldest first
PhoenixGenApi.ConfigFailed.list(order: :oldest_first)

# Count non-expired entries
PhoenixGenApi.ConfigFailed.count()

# Summary with counts by source and service
PhoenixGenApi.ConfigFailed.summary()
```

### Cleanup

Entries auto-expire after 24 hours. Call `cleanup/0` to purge expired entries:

```elixir
# Remove expired entries (returns count removed)
PhoenixGenApi.ConfigFailed.cleanup()

# Clear all entries regardless of expiry
PhoenixGenApi.ConfigFailed.clear()
```

### IEx Print Helpers

```elixir
# Print formatted table of failed entries
PhoenixGenApi.failed_configs_print()

# Print summary
PhoenixGenApi.failed_configs_summary()

# Clean up expired entries
PhoenixGenApi.cleanup_failed_configs()

# Clear all entries
PhoenixGenApi.clear_failed_configs()
```

### Example Output

```
=== Failed FunConfig Entries ===
Showing: 3 entries (limit: 100)

ID      Service              Request Type           Version    Source   Reason
------------------------------------------------------------------------------------------
42      user_service         get_user               1.0.0      pull     request_type must be a non-empty string
41      order_service        create_order           nil        push     MFA not allowed: {BadMod, :bad_fn, []}; service must not be nil
40      payment_service      process                2.0.0      pull     nodes must be a valid list, MFA tuple, or :local
```

---

## IEx Helpers

Convenience functions are available on the main `PhoenixGenApi` module:

```elixir
# Check overall system health
PhoenixGenApi.Diagnostics.health_check()

# Get detailed statistics
PhoenixGenApi.Diagnostics.statistics()

# See how a request flows through the system
PhoenixGenApi.Diagnostics.call_flow("user_service", "get_user")

# View cluster topology
PhoenixGenApi.Diagnostics.cluster_view()
```

Shell helpers on the main `PhoenixGenApi` module are listed in the [second IEx Helpers section](#iex-helpers-1) below.

---

## Health Checks

`health_check/1` returns a structured report with the overall system status and detailed checks for the VM, Erlang distribution, and all PhoenixGenApi processes.

```elixir
PhoenixGenApi.Diagnostics.health_check()
#=>
# %{
#   status: :ok,
#   node: :gateway@host,
#   checked_at_ms: 1718000000000,
#   checks: %{
#     vm: %{
#       status: :ok,
#       process_count: 1523,
#       process_limit: 262144,
#       memory: %{total: 45_000_000, processes: 30_000_000, ...},
#       schedulers: 8,
#       schedulers_online: 8,
#       uptime: {120, 500_000}
#     },
#     node: %{
#       status: :ok,
#       node: :gateway@host,
#       alive?: true,
#       connected_nodes: [:"service@host"]
#     },
#     phoenix_gen_api: %{
#       status: :ok,
#       mode: :gateway,
#       checks: %{
#         config_db: %{status: :ok, pid: #PID<0.300.0>, ...},
#         config_puller: %{status: :ok, pid: #PID<0.301.0>, ...},
#         rate_limiter_instances: %{status: :ok, instance_count: 8},
#         ...
#       }
#     }
#   }
# }
```

### Options

| Option | Type | Description |
|--------|------|-------------|
| `:max_memory_bytes` | `pos_integer` | If total memory exceeds this, the VM check is marked `:degraded` |

### Status Values

| Status | Meaning |
|--------|---------|
| `:ok` | All checks passed |
| `:degraded` | One or more checks are warning (e.g., high memory, unreachable node) |
| `:error` | One or more critical processes are down |

---

## Statistics

`statistics/1` returns detailed VM and PhoenixGenApi runtime counters.

```elixir
stats = PhoenixGenApi.Diagnostics.statistics()

# VM statistics
stats.vm.memory          # %{total: ..., processes: ..., system: ...}
stats.vm.process_count   # 1523
stats.vm.reductions      # {total_reductions, since_last_call}
stats.vm.runtime         # {total_run_time, time_since_last_call}
stats.vm.scheduler_wall_time  # [{scheduler_id, active, total}]

# PhoenixGenApi statistics
stats.phoenix_gen_api.config_db.count        # 42
stats.phoenix_gen_api.config_db.services     # ["user_service", "order_service"]
stats.phoenix_gen_api.rate_limiter.data.instances  # [...]
stats.phoenix_gen_api.worker_pool.async_pool.data  # %{idle_workers: 950, ...}
stats.phoenix_gen_api.relay.data.group_count       # 5
stats.phoenix_gen_api.telemetry_events             # 31
```

---

## Debug Reports

`debug_report/1` returns a snapshot of the top processes by memory usage, ETS table info, and trace status.

```elixir
report = PhoenixGenApi.Diagnostics.debug_report(process_limit: 10)

# Top 10 processes by memory
report.processes
# [%{pid: ..., registered_name: :async_pool, memory: 1_000_000, ...}, ...]

# ETS table info
report.ets_tables
# %{
#   "PhoenixGenApi.ConfigDb" => %{exists: true, size: 42, memory: 1234, ...},
#   ":rate_limiter_global" => %{exists: true, size: 1000, ...},
#   ...
# }

# Trace status
report.trace.trace_control_word
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:process_limit` | `pos_integer` | `20` | Max processes to include |
| `:include_current_stacktrace` | `boolean` | `false` | Include stacktraces |

---

## Call Flow Inspection

`call_flow/3` traces how a request flows from the gateway to its target nodes. This is the primary debugging tool for understanding request routing.

```elixir
flow = PhoenixGenApi.Diagnostics.call_flow("user_service", "get_user")

# Basic info
flow.config           # %FunConfig{} or nil
flow.local?           # true | false
flow.nodes            # [:"service@host", :"service2@host"]
flow.reachable_nodes  # [:"service@host"]
flow.unreachable_nodes # [:"service2@host"]
flow.response_type    # :sync | :async | :stream | :none
flow.choose_node_mode # :random | :hash | :round_robin | :sticky
flow.timeout          # 5000
flow.mfa              # {MyApp.Api, :get_user, []}

# Rate limit scopes
flow.rate_limit.global  # [%{scope: :global, key: :user_id, max_requests: 2000, ...}]
flow.rate_limit.api     # [%{scope: :api, key: :user_id, max_requests: 10, ...}]

# Permission strategy
flow.permission.strategy    # :none | :authenticated | :arg_based | :role_based | :custom_mfa
flow.permission.description # "Requires authenticated user_id"

# Hooks
flow.hooks.before_execute.configured  # true | false
flow.hooks.before_execute.mfa         # {MyApp.Hooks, :before_get_user}
flow.hooks.after_execute.configured   # true | false

# Retry
flow.retry.configured  # true | false
flow.retry.mode        # :same_node | :all_nodes
flow.retry.attempts    # 3

# Execution steps (ordered)
flow.steps
# [
#   %{phase: :channel, desc: "WebSocket handle_in receives payload on channel"},
#   %{phase: :decode, desc: "Payload decoded into %Request{} via Nestru"},
#   %{phase: :config_lookup, desc: "ConfigDb.get(...) — direct ETS read"},
#   %{phase: :hooks_before, desc: "before_execute hooks (none configured)"},
#   %{phase: :permission, desc: "Permission.check_permission!/2"},
#   %{phase: :rate_limit, desc: "RateLimiter.check_rate_limit/1 — sliding window check"},
#   %{phase: :argument_validation, desc: "ArgumentHandler.convert_args!/2"},
#   %{phase: :node_selection, desc: "NodeSelector picks :random from [service@host]"},
#   %{phase: :execution, desc: "RPC to target node(s) — 1/1 reachable"},
#   %{phase: :hooks_after, desc: "after_execute hooks (none configured)"},
#   %{phase: :response, desc: "Sync result pushed back to client via WebSocket"}
# ]
```

### Call Flow Diagram

```
Client Request (WebSocket)
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│ 1. Channel handle_in                                    │
│    Decode payload → %Request{}                          │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 2. ConfigDb.get(service, type, version)                 │
│    Direct ETS lookup (no GenServer call)                │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 3. before_execute hooks                                 │
│    Can modify request or abort                          │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 4. Permission.check_permission!(request, fun_config)    │
│    :none | :authenticated | :arg_based | :role_based    │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 5. RateLimiter.check_rate_limit(request)                │
│    Sliding window, multi-instance, fail-open            │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 6. ArgumentHandler.convert_args!(fun_config, request)   │
│    Type checking & conversion                           │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 7. Node Selection (remote only)                         │
│    :random | :hash | :round_robin | {:sticky, key}      │
└─────────────────────┬───────────────────────────────────┘
                      │
              ┌───────┴───────┐
              │               │
              ▼               ▼
     ┌────────────┐   ┌────────────┐
     │ Local Exec │   │ Remote RPC │
     │ Task.async │   │ :rpc.call  │
     └──────┬─────┘   └──────┬─────┘
            │                │
            └───────┬────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────┐
│ 8. Retry (if configured and error)                      │
│    {:same_node, n} | {:all_nodes, n}                     │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 9. after_execute hooks                                  │
│    Can modify response or log                           │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│ 10. Response                                            │
│     :sync → push to client                              │
│     :async → push when ready                            │
│     :stream → push chunks                               │
│     :none → no response                                 │
└─────────────────────────────────────────────────────────┘
```

---

## Cluster View

`cluster_view/0` returns the cluster topology from the perspective of the current node.

```elixir
view = PhoenixGenApi.Diagnostics.cluster_view()

view.self                # :gateway@host
view.connected           # [:"service@host", :"service2@host"]
view.connected_count     # 2

# Registered processes on each node
view.registered_processes
# %{
#   :gateway@host => [PhoenixGenApi.Supervisor, PhoenixGenApi.ConfigDb, ...],
#   :"service@host" => [PhoenixGenApi.ConfigDb, ...]
# }

# PhoenixGenApi services on each connected node
view.phoenix_gen_api_services
# %{
#   :"service@host" => ["user_service", "order_service"],
#   :"service2@host" => ["inventory_service"]
# }
```

---

## Request Inspection

`inspect_request/1` takes a `%Request{}` struct (or map) and returns the full execution plan.

```elixir
request = %PhoenixGenApi.Structs.Request{
  request_id: "req_123",
  service: "user_service",
  request_type: "get_user",
  user_id: "user_456",
  args: %{"user_id" => "user_789"}
}

plan = PhoenixGenApi.Diagnostics.inspect_request(request)

plan.request       # Normalized request fields
plan.config        # Resolved FunConfig
plan.nodes         # Target nodes
plan.steps         # Execution steps
plan.local?        # true | false
```

This is useful for debugging why a request routes to a particular node or fails at a specific phase.

---

## Listing All Call Flows

`list_call_flows/1` returns a summary of all registered call flows across all services.

```elixir
flows = PhoenixGenApi.Diagnostics.list_call_flows()

# Each entry:
# %{
#   service: "user_service",
#   request_type: "get_user",
#   version: "1.0.0",
#   local?: false,
#   nodes: [:"service@host"],
#   response_type: :sync,
#   disabled: false,
#   steps: [...]
# }

# Include disabled configs
flows = PhoenixGenApi.Diagnostics.list_call_flows(include_disabled: true)
```

---

## Tracing

Tracing is gated behind admin actions to prevent accidental overhead. Configure before use:

```elixir
config :phoenix_gen_api, :admin_actions, [
  :enable_tracing,
  :disable_tracing
]
```

### Trace Processes

```elixir
# Trace all processes for calls, returns, and process events
{:ok, result} = PhoenixGenApi.Diagnostics.trace_processes(:all,
  flags: [:call, :return_to, :procs],
  tracer: self()
)

# Trace specific PID
{:ok, result} = PhoenixGenApi.Diagnostics.trace_processes(some_pid)

# Stop tracing
{:ok, result} = PhoenixGenApi.Diagnostics.stop_trace(:all)
```

### Trace Functions (MFA)

```elixir
# Trace all arities of a function
{:ok, result} = PhoenixGenApi.Diagnostics.trace_functions({MyApp.Api, :get_user, :_},
  tracer: self()
)

# Trace specific arity
{:ok, result} = PhoenixGenApi.Diagnostics.trace_functions({MyApp.Api, :get_user, 1})

# Trace all functions (use with caution!)
{:ok, result} = PhoenixGenApi.Diagnostics.trace_functions(:all)

# Stop tracing
{:ok, result} = PhoenixGenApi.Diagnostics.stop_trace_functions({MyApp.Api, :get_user, :_})
```

### Trace Flags

| Flag | Description |
|------|-------------|
| `:call` | Trace function calls |
| `:return_to` | Trace return_to events |
| `:return_trace` | Trace return values |
| `:procs` | Trace process events (spawn, exit, etc.) |
| `:ports` | Trace port events |
| `:timestamp` | Add timestamps |
| `:cpu_timestamp` | Add CPU timestamps |
| `:arity` | Include arity in call traces |
| `:silent` | Suppress trace messages |

### Trace Status

```elixir
PhoenixGenApi.Diagnostics.trace_status()
# %{node: :gateway@host, trace_control_word: 0}
```

---

## IEx Helpers

Convenience functions are available on the main `PhoenixGenApi` module:

```elixir
# Health & Statistics
PhoenixGenApi.health_check()
PhoenixGenApi.health_check(max_memory_bytes: 100_000_000)
PhoenixGenApi.statistics()
PhoenixGenApi.debug_report(process_limit: 10)

# Call Flow
PhoenixGenApi.call_flow("user_service", "get_user")
PhoenixGenApi.cluster_view()
PhoenixGenApi.list_call_flows()

# Tracing (requires admin action)
PhoenixGenApi.trace_processes(:all, flags: [:call, :procs])
PhoenixGenApi.trace_functions({MyApp.Api, :get_user, 1})
PhoenixGenApi.stop_trace(:all)
PhoenixGenApi.stop_trace_functions(:all)
PhoenixGenApi.trace_status()
```

---

## Integration Patterns

### Periodic Health Monitoring

```elixir
# In a GenServer or Task
def handle_info(:check_health, state) do
  case PhoenixGenApi.Diagnostics.health_check() do
    %{status: :ok} ->
      :ok

    %{status: :degraded, checks: checks} ->
      Logger.warning("[Monitor] System degraded: #{inspect(checks)}")

    %{status: :error, checks: checks} ->
      Logger.error("[Monitor] System error: #{inspect(checks)}")
      # Alert on-call, page, etc.
  end

  Process.send_after(self(), :check_health, 30_000)
  {:noreply, state}
end
```

### Dashboard Integration

```elixir
# In a LiveView or controller
def handle_event("refresh_stats", _, socket) do
  stats = PhoenixGenApi.Diagnostics.statistics()
  {:noreply, assign(socket, :stats, stats)}
end
```

### Debugging a Failing Request

```elixir
# 1. Check the call flow
flow = PhoenixGenApi.Diagnostics.call_flow("my_service", "my_action")
IO.inspect(flow.reachable_nodes, label: "Reachable nodes")
IO.inspect(flow.steps, label: "Execution steps")

# 2. Check if the target node is connected
view = PhoenixGenApi.Diagnostics.cluster_view()
IO.inspect(view.connected, label: "Connected nodes")

# 3. Inspect a specific request
plan = PhoenixGenApi.Diagnostics.inspect_request(%{
  service: "my_service",
  request_type: "my_action",
  user_id: "user_123"
})

# 4. Enable tracing to see the actual calls
PhoenixGenApi.Diagnostics.trace_functions({MyApp.Api, :my_action, :_}, tracer: self())

# ... make the request ...

# 5. Disable tracing
PhoenixGenApi.Diagnostics.stop_trace_functions({MyApp.Api, :my_action, :_})
```

### Production Debugging Workflow

```elixir
# Step 1: Check overall health
PhoenixGenApi.Diagnostics.health_check()

# Step 2: If degraded, check which component
# Step 3: Look at the specific call flow
PhoenixGenApi.Diagnostics.call_flow("problem_service", "problem_action")

# Step 4: Check cluster connectivity
PhoenixGenApi.Diagnostics.cluster_view()

# Step 5: If needed, enable targeted tracing
PhoenixGenApi.Diagnostics.trace_processes(:existing, flags: [:call, :return_to])

# Step 6: Analyze trace messages, then disable
PhoenixGenApi.Diagnostics.stop_trace(:all)
```

## Request Tracing

### Why Trace?

When an API misbehaves for a specific user or request type, you want to see exactly
what happened without logging every request globally. Tracing lets you:

- Focus on one request type (e.g. `"checkout"`) or one user id (e.g. `"user_123"`)
- See the full request payload, permission decision, and result for each matching request
- Correlate a request across gateway and service nodes using the request id
- Turn it on and off at runtime with a single function call — no restart

### How It Works

Tracing is **opt-in** and **off by default**. It only writes when a request matches
an explicitly enabled request type or user id.

When a request flows through `PhoenixGenApi.Executor.execute!/1`, every action that
request takes is traced:

1. **Request start** — emitted when execution begins (includes `args`)
2. **Configuration lookup** — the service/request-type config was found or not
3. **Before hooks** — `before_execute` hooks, including failures
4. **Rate limiting** — allowed, limited (with `retry_after_ms`), or error
5. **Permission** — the permission decision (includes mode and result)
6. **Arguments** — argument conversion succeeded or failed (with arg count)
7. **Execution** — the local or remote MFA invocation
8. **Retries** — each retry attempt (local and remote) and exhaustion
9. **RPC fallback** — node failover when a remote node times out or errors
10. **Async/stream** — queued, queue full, started, timeout, or error
11. **After hooks** — `after_execute` hooks, including failures
12. **Raw `Logger` output** — every log line emitted while the request is traced
13. **Request end** — emitted when execution finishes (includes success, duration, error)

### Raw Log Capture

While a request is traced, the **raw `Logger` output** of every module that touches
the request is captured too — executor, rate limiter, argument handler, config db,
hooks, permission, node selector, stream calls, and the worker pool. Each captured
log line looks like:

```text
timestamp=... node=... event=log level=warning pid=<0.123.0> mfa=Elixir.PhoenixGenApi.Executor.apply_local_retry/2 request_id=req_1 message="[Executor] retrying, mode: :local"
```

Capture is driven by **process metadata**: tracing attaches `phoenix_gen_api_trace`
and `phoenix_gen_api_trace_request` metadata to the request's process, and the 
capture handler forwards any log emitted by that process to the trace file. Logs
from worker processes (async calls, stream calls, worker pool) are captured because
the executor re-applies the metadata in those processes.

To see debug/info logs, tracing temporarily raises the global `Logger` level to
`:log_level` while enabled (see below) and restores it on disable. To keep untraced
debug/info traffic off the console during capture, a suppression filter is installed
on the `:default` handler.

### Manual Control

The checkpoint functions can also be used directly to trace a request by hand:

```elixir
ctx = PhoenixGenApi.Tracer.begin_trace(request)   # nil if the request is not traced
PhoenixGenApi.Tracer.trace_event("my_step", %{"status" => "ok"})
PhoenixGenApi.Tracer.end_trace(ctx)               # restores process metadata
```

`trace_event/2` and raw log capture are no-ops unless a trace context is active
(`begin_trace/1` returned a non-nil context).

If the request matches an enabled request type, the line is appended to that
request type's file. If it matches an enabled user id, the same line is appended
to that user id's file. A request matching both is written to both files.

The hot-path check is intentionally tiny: a single in-memory lookup that returns
immediately when tracing is disabled or the request matches nothing. File I/O is
performed **asynchronously** by a dedicated writer process, so request execution
is never blocked.

### Enabling Tracing

### At Runtime (Functions)

```elixir
# Trace a single request type
PhoenixGenApi.Tracer.enable_request_type("get_user")

# Trace several request types at once
PhoenixGenApi.Tracer.enable_request_type(["get_user", "create_order"])

# Trace all requests for a specific user
PhoenixGenApi.Tracer.enable_user_id("user_123")

# Stop tracing
PhoenixGenApi.Tracer.disable_request_type("get_user")
PhoenixGenApi.Tracer.disable_user_id("user_123")

# Toggle the global switch (off by default)
PhoenixGenApi.Tracer.set_enabled(true)
PhoenixGenApi.Tracer.set_enabled(false)

# Remove all traced keys
PhoenixGenApi.Tracer.clear()
```

Convenience functions are also available on the top-level `PhoenixGenApi` module:

```elixir
PhoenixGenApi.enable_trace_request_type("get_user")
PhoenixGenApi.enable_trace_user_id("user_123")
PhoenixGenApi.disable_trace_request_type("get_user")
PhoenixGenApi.disable_trace_user_id("user_123")
PhoenixGenApi.tracer_status()
```

### Via Configuration

```elixir
config :phoenix_gen_api, :tracer,
  enabled: true,
  log_dir: "log/phoenix_gen_api_traces",
  max_file_bytes: 50_000_000,
  max_backup_files: 5,
  log_level: :debug,
  request_types: ["get_user"],
  user_ids: ["user_123"]
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:enabled` | `boolean` | `false` | Global on/off switch |
| `:log_dir` | `String.t()` | `"log/phoenix_gen_api_traces"` | Directory for the per-key trace files |
| `:max_file_bytes` | `integer` | `50_000_000` | Rotate a trace file once it exceeds this size |
| `:max_backup_files` | `integer` | `5` | How many rotated `.1`, `.2`, ... files to keep |
| `:log_level` | atom or string | `:debug` | `Logger` level raised globally while tracing is enabled |
| `:request_types` | `String.t()` or list | `[]` | Request types to trace at startup |
| `:user_ids` | `String.t()` or list | `[]` | User ids to trace at startup |

`:request_types` and `:user_ids` accept a single string or a list of strings.
Invalid entries (non-strings, empty strings) are ignored. `:log_level` accepts
`:debug`, `:info`, `:warning` (or `:warn`) and their string forms.

### Trace Files

Files are named after the traced key, under `:log_dir`:

```text
log/phoenix_gen_api_traces/
├── request_type-get_user.log
├── request_type-create_order.log
└── user_id-user_123.log
```

Keys are sanitized for the filesystem (`/`, `\`, `:`, `*`, `?`, spaces, etc. are
replaced with `_`).

Each line is space-separated `key=value`:

```text
timestamp=2026-08-17T12:00:00.000Z node=app@host event=request_start request_id=req_1 user_id=user_123 device_id=dev_1 request_type=get_user service=user_service version=nil args="%{\"id\" => \"u1\"}"
```

### Trace Events

| Event | Trigger | Notable fields |
|-------|---------|----------------|
| `request_start` | `Executor.execute!/1` begins | `args` |
| `config_lookup` | Config for service/request-type resolved | `status` (`ok`/`not_found`/`disabled`), `version` |
| `hook_before` | `before_execute` hook runs | `status` (`ok`/`error`), `error` |
| `rate_limit` | Rate limiter decides | `status` (`allowed`/`limited`/`error`), `retry_after_ms` |
| `permission` | Permission check completes | `permission`, `permission_mode` |
| `arguments` | Arguments converted | `status` (`ok`/`error`), `count`, `error` |
| `execution` | MFA invoked | `mode` (`local`/`remote`), `mfa` |
| `error` | Execution raised/exited/errored | `kind`, `error` |
| `retry` | A retry attempt starts | `attempt`, `type` (`local`/`remote`), `backoff_ms`, `result` |
| `retry_exhausted` | All retries failed | `type`, `result` |
| `rpc_fallback` | Remote node failed, failing over | `node`, `reason` |
| `async` | Async call dispatched | `status` (`queued`/`queue_full`) |
| `stream` | Stream call lifecycle | `status` (`started`/`queue_full`/`timeout`/`error`) |
| `hook_after` | `after_execute` hook runs | `status` (`ok`/`error`), `error` |
| `log` | A raw `Logger` line was emitted during the trace | `level`, `pid`, `mfa`, `message` |
| `request_end` | Execution finishes | `success`, `async`, `duration_us`, `error` |

Common fields on every event: `timestamp`, `node`, `request_id`, `user_id`,
`device_id`, `request_type`, `service`, `version`.

The `permission_mode` reflects the configured strategy, e.g. `{:arg, "user_id"}`,
`:any_authenticated`, `{:role, ["admin"]}`, or `{:callback, {Mod, :fun, []}}`.

The `error` field is `nil` on success and holds the error term on failure.
`request_start` events include the full `args`; `request_end` events include
`success`, `async`, and `duration_us`.

### Rotating Trace Files

Trace files grow while tracing is enabled. When a file exceeds `:max_file_bytes`
it is rotated: the current file becomes `<file>.1`, previous backups shift up
(`.1` → `.2`, ...), and a fresh file is opened. `:max_backup_files` caps how many
rotated files are retained; older backups are deleted.

For example, with `max_file_bytes: 50_000_000` and `max_backup_files: 5`:

```text
request_type-get_user.log        # current, up to 50 MB
request_type-get_user.log.1      # previous
request_type-get_user.log.2      # older
...up to .5
```

Writer settings can also be updated at runtime:

```elixir
PhoenixGenApi.Tracer.configure(log_dir: "log/traces", max_file_bytes: 100_000_000)
```

### Inspecting State

```elixir
# Is tracing globally enabled?
PhoenixGenApi.Tracer.enabled?()       # => true

# Which keys are currently traced?
PhoenixGenApi.Tracer.enabled_request_types()
PhoenixGenApi.Tracer.enabled_user_ids()

# Full status snapshot (config + open trace files + their sizes)
PhoenixGenApi.Tracer.status()

# Block until the writer has flushed pending lines (for scripts/tests)
PhoenixGenApi.Tracer.flush()
```

### Performance

Tracing is designed to not degrade request throughput:

- When tracing is **disabled** or a request matches nothing, the cost is a single
  in-memory lookup — no file access, no message passing.
- Only matching requests send an asynchronous message to the writer process.
  The writer serializes file I/O, so the request path never waits on disk.
- Tracing is opt-in, so the amount of traced traffic is controlled by what you
  explicitly enable (a specific request type or user id), not the full request load.

### Example: Debugging a Single User

A user reports that their requests fail intermittently. You want to see everything
that user sends without enabling tracing for the whole API:

```elixir
# In IEx on the gateway node
PhoenixGenApi.enable_trace_user_id("user_123")

# Let the user retry, then inspect their dedicated file
PhoenixGenApi.tracer_status()
# => %{log_dir: "log/phoenix_gen_api_traces", user_ids: ["user_123"], ...}

# Each line shows request_start → permission → request_end
tail -f log/phoenix_gen_api_traces/user_id-user_123.log

# Done investigating
PhoenixGenApi.disable_trace_user_id("user_123")
```

Because the file also carries `request_type` and `request_id`, you can correlate a
single request across the cluster even when it is routed to a service node.

---

## What's Next

- **[Architecture](./architecture.md)** — Request lifecycle and line-by-line execution walkthrough.
- **[Architecture](./architecture.md)** — Deep dive into the supervision tree, request lifecycle, and all subsystems.
- **[Telemetry](./telemetry.md)** — Full event reference and integration patterns for observability.
