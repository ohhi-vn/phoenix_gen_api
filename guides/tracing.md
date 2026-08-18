# Tracing Guide

PhoenixGenApi can trace individual requests and write them to dedicated log files.
Tracing is keyed by **request type** and/or **user id** — enable exactly what you
want to observe, and every matching request gets written to its own file. This is
designed for debugging a single API, a single user, or a small subset of traffic
in production without affecting performance.

## Table of Contents

- [Why Trace?](#why-trace)
- [How It Works](#how-it-works)
- [Enabling Tracing](#enabling-tracing)
  - [At Runtime (Functions)](#at-runtime-functions)
  - [Via Configuration](#via-configuration)
- [Trace Files](#trace-files)
- [Trace Events](#trace-events)
- [Rotating Trace Files](#rotating-trace-files)
- [Inspecting State](#inspecting-state)
- [Performance](#performance)
- [Example: Debugging a Single User](#example-debugging-a-single-user)

---

## Why Trace?

When an API misbehaves for a specific user or request type, you want to see exactly
what happened without logging every request globally. Tracing lets you:

- Focus on one request type (e.g. `"checkout"`) or one user id (e.g. `"user_123"`)
- See the full request payload, permission decision, and result for each matching request
- Correlate a request across gateway and service nodes using the request id
- Turn it on and off at runtime with a single function call — no restart

## How It Works

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

## Enabling Tracing

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

## Trace Files

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

## Trace Events

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

## Rotating Trace Files

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

## Inspecting State

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

## Performance

Tracing is designed to not degrade request throughput:

- When tracing is **disabled** or a request matches nothing, the cost is a single
  in-memory lookup — no file access, no message passing.
- Only matching requests send an asynchronous message to the writer process.
  The writer serializes file I/O, so the request path never waits on disk.
- Tracing is opt-in, so the amount of traced traffic is controlled by what you
  explicitly enable (a specific request type or user id), not the full request load.

## Example: Debugging a Single User

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