# Telemetry Integration Guide

PhoenixGenApi emits structured telemetry events throughout its lifecycle using the
[`:telemetry`](https://hexdocs.pm/telemetry/) library. This guide covers how to
discover, attach to, and handle these events for monitoring, metrics, and observability.

## Table of Contents

- [Quick Start](#quick-start)
- [The Telemetry Module](#the-telemetry-module)
- [Event Reference](#event-reference)
  - [Executor Events](#executor-events)
  - [Rate Limiter Events](#rate-limiter-events)
  - [Hook Events](#hook-events)
  - [Worker Pool Events](#worker-pool-events)
  - [Config Cache Events](#config-cache-events)
- [Integration Patterns](#integration-patterns)
  - [Console Logging](#console-logging)
  - [Request Duration Metrics](#request-duration-metrics)
  - [Error Rate Tracking](#error-rate-tracking)
  - [Rate Limit Monitoring](#rate-limit-monitoring)
  - [Circuit Breaker Alerts](#circuit-breaker-alerts)
  - [Distributed Tracing](#distributed-tracing)
- [Using with Telemetry.Metrics](#using-with-telemetrymetrics)
- [Using with LiveDashboard](#using-with-livedashboard)
- [Best Practices](#best-practices)

## Quick Start

### Attach to all events

```elixir
# In your application's start callback or a dedicated supervisor
PhoenixGenApi.Telemetry.attach_all("my-app", fn event, measurements, metadata, _config ->
  Logger.info("[Telemetry] #{inspect(event)} #{inspect(measurements)}")
end)
```

### Attach to a specific category

```elixir
# Only executor events
PhoenixGenApi.Telemetry.attach_executor("my-app-executor", fn event, measurements, metadata, _config ->
  case event do
    [:phoenix_gen_api, :executor, :request, :stop] ->
      Logger.info("Request #{metadata.request_id} completed in #{measurements.duration_us}µs")
    [:phoenix_gen_api, :executor, :request, :exception] ->
      Logger.error("Request #{metadata.request_id} failed: #{metadata.reason}")
    _ ->
      :ok
  end
end)
```

### Attach to a single event

```elixir
:telemetry.attach(
  "rate-limit-monitor",
  [:phoenix_gen_api, :rate_limiter, :exceeded],
  fn _event, measurements, metadata, _config ->
    Logger.warning(
      "Rate limit exceeded for user=#{metadata.user_id} " <>
      "key=#{metadata.key} current=#{metadata.current_requests}/#{metadata.max_requests} " <>
      "retry_after=#{measurements.retry_after_ms}ms"
    )
  end,
  %{}
)
```

### Built-in debug logger

```elixir
# Attach a debug-level console logger for all events
PhoenixGenApi.Telemetry.attach_default_logger()

# Later, detach it
PhoenixGenApi.Telemetry.detach_default_logger()
```

## The Telemetry Module

`PhoenixGenApi.Telemetry` is the centralized module for discovering and attaching to
telemetry events. It provides:

| Function | Description |
|----------|-------------|
| `list_events/0` | Returns all 28 event names as a list |
| `attach_all/3` | Attach a handler to all events |
| `attach_executor/3` | Attach to 4 executor events |
| `attach_rate_limiter/3` | Attach to 4 rate limiter events |
| `attach_hooks/3` | Attach to 6 hook events |
| `attach_worker_pool/3` | Attach to 5 worker pool events |
| `attach_config/3` | Attach to 9 config cache events |
| `attach_many/4` | Attach to a custom list of events |
| `detach_all/1` | Detach all handlers for a handler ID |
| `attach_default_logger/1` | Attach a debug console logger |
| `detach_default_logger/1` | Detach the default logger |
| `execute/3` | Emit a custom telemetry event |
| `span/3` | Emit start/stop/exception events around a function |

All `attach_*` functions share the same signature:

```elixir
attach_*(handler_id :: String.t(), function :: function(), config :: map()) :: :ok
```

The handler function signature is:

```elixir
(event_name :: [atom()], measurements :: map(), metadata :: map(), config :: any()) :: any()
```

## Event Reference

PhoenixGenApi emits **28 telemetry events** across 5 categories. All event names are
prefixed with `:phoenix_gen_api`.

### Executor Events

Emitted during the request execution lifecycle in `PhoenixGenApi.Executor`.

#### `[:phoenix_gen_api, :executor, :request, :start]`

Emitted at the beginning of every request, before config lookup.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | `integer()` | System time in native units |
| **Metadata** | | |
| `request_id` | `String.t()` | Unique request identifier |
| `request_type` | `String.t()` | API request type name |
| `service` | `String.t()` | Service name |
| `user_id` | `String.t()` | User making the request |

#### `[:phoenix_gen_api, :executor, :request, :stop]`

Emitted after successful request execution (including when the response indicates
a business-level failure — check `success` metadata).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `request_id` | `String.t()` | Unique request identifier |
| `request_type` | `String.t()` | API request type name |
| `service` | `String.t()` | Service name |
| `user_id` | `String.t()` | User making the request |
| `success` | `boolean()` | Whether the response was successful |
| `async` | `boolean()` | Whether the response was async |

#### `[:phoenix_gen_api, :executor, :request, :exception]`

Emitted when an unhandled exception occurs during request execution. The exception
is re-raised after the event is emitted.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds before the exception |
| **Metadata** | | |
| `request_id` | `String.t()` | Unique request identifier |
| `request_type` | `String.t()` | API request type name |
| `service` | `String.t()` | Service name |
| `user_id` | `String.t()` | User making the request |
| `kind` | `:error` | Exception kind |
| `reason` | `String.t()` | Exception message |
| `stacktrace` | `Exception.stacktrace()` | Stack trace |

#### `[:phoenix_gen_api, :executor, :retry]`

Emitted before each retry attempt when the previous attempt returned a retryable error
and retries remain. The `attempt` measurement counts down (remaining retries, not
attempt number).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `attempt` | `non_neg_integer()` | Remaining retry count |
| **Metadata** | | |
| `mode` | `:same_node \| :all_nodes` | Retry strategy |
| `type` | `:local \| :remote` | Execution type |
| `nodes` | `list()` | *(remote retries only)* Target node list |

> **Note:** The `nodes` key is only present for remote retries. Local retries emit
> `%{mode: mode, type: :local}` without a `nodes` key.

### Rate Limiter Events

Emitted by `PhoenixGenApi.RateLimiter` during rate limit checks and maintenance.

#### `[:phoenix_gen_api, :rate_limiter, :check]`

Emitted after every rate limit check, regardless of outcome.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration of the check in microseconds |
| **Metadata** | | |
| `request_id` | `String.t()` | Request identifier |
| `user_id` | `String.t()` | User identifier |
| `service` | `String.t()` | Service name |
| `request_type` | `String.t()` | API request type |
| `result` | `:ok \| {:error, :rate_limited, map()}` | Check result |

To determine if the request was allowed:

```elixir
allowed = match?(:ok, metadata.result)
```

#### `[:phoenix_gen_api, :rate_limiter, :exceeded]`

Emitted when a rate limit is exceeded (after the `:check` event).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `retry_after_ms` | `non_neg_integer()` | Milliseconds until the window resets |
| **Metadata** | | |
| `key` | `String.t()` | The rate limit key that was exceeded |
| `scope` | `:global \| {String.t(), String.t()}` | Scope of the rate limit |
| `max_requests` | `non_neg_integer()` | Configured maximum |
| `current_requests` | `non_neg_integer()` | Current count that exceeded the limit |
| `request_id` | `String.t()` | Request identifier |
| `user_id` | `String.t()` | User identifier |

#### `[:phoenix_gen_api, :rate_limiter, :reset]`

Emitted when a rate limit counter is manually reset.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `key` | `String.t()` | The key value that was reset |
| `scope` | `atom()` | The scope of the reset |
| `rate_limit_key` | `atom()` | The rate limit key type |

#### `[:phoenix_gen_api, :rate_limiter, :cleanup]`

Emitted periodically when the cleanup timer fires and stale entries are removed.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration of cleanup in microseconds |
| `cleaned_entries` | `non_neg_integer()` | Number of entries removed |
| **Metadata** | | |
| `global_limits_count` | `non_neg_integer()` | Number of global limit configs |
| `api_limits_count` | `non_neg_integer()` | Number of API-specific limit configs |

### Hook Events

Emitted by `PhoenixGenApi.Hooks` when before/after execution hooks run. The `type`
field in metadata distinguishes between `:before` and `:after` hooks.

#### `[:phoenix_gen_api, :hook, :before, :start]`

Emitted before executing a before-hook callback.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | `integer()` | System time in native units |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:before` | Hook type |

#### `[:phoenix_gen_api, :hook, :before, :stop]`

Emitted after a before-hook callback completes successfully.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:before` | Hook type |

#### `[:phoenix_gen_api, :hook, :before, :exception]`

Emitted when a before-hook callback raises an exception.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:before` | Hook type |
| `kind` | `:error` | Exception kind |
| `reason` | `String.t()` | Exception message |
| `stacktrace` | `Exception.stacktrace()` | Stack trace |

#### `[:phoenix_gen_api, :hook, :after, :start]`

Emitted before executing an after-hook callback.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | `integer()` | System time in native units |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:after` | Hook type |

#### `[:phoenix_gen_api, :hook, :after, :stop]`

Emitted after an after-hook callback completes successfully.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:after` | Hook type |

#### `[:phoenix_gen_api, :hook, :after, :exception]`

Emitted when an after-hook callback raises an exception.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `module` | `module()` | Hook module |
| `function` | `atom()` | Hook function name |
| `type` | `:after` | Hook type |
| `kind` | `:error` | Exception kind |
| `reason` | `String.t()` | Exception message |
| `stacktrace` | `Exception.stacktrace()` | Stack trace |

### Worker Pool Events

Emitted by `PhoenixGenApi.WorkerPool` during task execution and circuit breaker
state changes.

#### `[:phoenix_gen_api, :worker_pool, :task, :start]`

Emitted when a worker begins executing a task.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | `integer()` | System time in native units |
| **Metadata** | | |
| `pool_name` | `atom()` | Name of the worker pool |

#### `[:phoenix_gen_api, :worker_pool, :task, :stop]`

Emitted when a task completes successfully.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `pool_name` | `atom()` | Name of the worker pool |

#### `[:phoenix_gen_api, :worker_pool, :task, :exception]`

Emitted when a task fails (exception, timeout, or abnormal exit).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| **Metadata** | | |
| `pool_name` | `atom()` | Name of the worker pool |
| `kind` | `:error \| :timeout \| atom()` | Failure kind |
| `reason` | `String.t() \| term()` | Error message or inspected value |
| `stacktrace` | `Exception.stacktrace() \| nil` | Stack trace (nil for catches/timeouts) |

#### `[:phoenix_gen_api, :worker_pool, :circuit_breaker, :open]`

Emitted when consecutive failures reach the circuit breaker threshold, causing the
pool to stop accepting new tasks.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `pool_name` | `atom()` | Name of the worker pool |
| `consecutive_failures` | `non_neg_integer()` | Failure count that triggered the breaker |

#### `[:phoenix_gen_api, :worker_pool, :circuit_breaker, :close]`

Emitted when a task succeeds after the circuit breaker had been open, resetting the
pool to accept new tasks.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `pool_name` | `atom()` | Name of the worker pool |

### Config Cache Events

Emitted by `PhoenixGenApi.ConfigDb`, `ConfigPuller`, and `ConfigReceiver` during
configuration management operations.

#### `[:phoenix_gen_api, :config, :pull, :start]`

Emitted before pulling configuration from a remote service.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `system_time` | `integer()` | System time in native units |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service being pulled |

#### `[:phoenix_gen_api, :config, :pull, :stop]`

Emitted after a config pull completes (success or failure).

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_us` | `integer()` | Duration in microseconds |
| `count` | `non_neg_integer()` | Number of configs fetched |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service that was pulled |
| `version` | `String.t() \| nil` | Config version (nil on error) |

#### `[:phoenix_gen_api, :config, :push]`

Emitted after configs are pushed from a remote node and stored.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | `non_neg_integer()` | Number of configs stored |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name |
| `version` | `String.t()` | Config version |

#### `[:phoenix_gen_api, :config, :add]`

Emitted when a single `FunConfig` is added or updated in the ETS cache.

> **Note:** Both `ConfigDb.add/1` and `ConfigDb.update/1` emit this event. There is
> no separate `:update` event.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name |
| `request_type` | `String.t()` | API request type |
| `version` | `String.t()` | Config version |

#### `[:phoenix_gen_api, :config, :batch_add]`

Emitted when multiple `FunConfig` entries are inserted in bulk.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | `non_neg_integer()` | Number of entries inserted |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name (from first entry) |

#### `[:phoenix_gen_api, :config, :delete]`

Emitted before deleting a config from the ETS cache.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name |
| `request_type` | `String.t()` | API request type |
| `version` | `String.t()` | Config version |

#### `[:phoenix_gen_api, :config, :clear]`

Emitted before clearing all configs.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `service` | `:all` | Always `:all` |
| `request_type` | `:all` | Always `:all` |
| `version` | `:all` | Always `:all` |

#### `[:phoenix_gen_api, :config, :disable]`

Emitted when a config is marked as disabled.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name |
| `request_type` | `String.t()` | API request type |
| `version` | `String.t()` | Config version |

#### `[:phoenix_gen_api, :config, :enable]`

Emitted when a config is re-enabled.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| *(empty)* | `%{}` | |
| **Metadata** | | |
| `service` | `String.t() \| atom()` | Service name |
| `request_type` | `String.t()` | API request type |
| `version` | `String.t()` | Config version |

## Integration Patterns

### Console Logging

The simplest integration — log all events to the console for development:

```elixir
# In application.ex start callback
PhoenixGenApi.Telemetry.attach_default_logger()
```

Or create a custom logger with filtering:

```elixir
defmodule MyApp.TelemetryLogger do
  require Logger

  def handle_event(event, measurements, metadata, _config) do
    case event do
      [:phoenix_gen_api, :executor, :request, :exception] ->
        Logger.error(
          "[Executor] Request #{metadata.request_id} failed: " <>
          "#{metadata.kind}: #{metadata.reason}"
        )

      [:phoenix_gen_api, :rate_limiter, :exceeded] ->
        Logger.warning(
          "[RateLimiter] Limit exceeded for user=#{metadata.user_id} " <>
          "key=#{metadata.key} (#{metadata.current_requests}/#{metadata.max_requests})"
        )

      [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open] ->
        Logger.error(
          "[WorkerPool] Circuit breaker OPEN for #{metadata.pool_name} " <>
          "after #{metadata.consecutive_failures} failures"
        )

      _ ->
        :ok
    end
  end
end

# Attach it
PhoenixGenApi.Telemetry.attach_all("my-app-logger", &MyApp.TelemetryLogger.handle_event/4)
```

### Request Duration Metrics

Track request latency percentiles by service and request type:

```elixir
defmodule MyApp.RequestMetrics do
  @moduledoc """
  Collects request duration metrics from PhoenixGenApi executor events.
  """

  def attach do
    :telemetry.attach(
      "request-duration-metrics",
      [:phoenix_gen_api, :executor, :request, :stop],
      &__MODULE__.handle_stop/4,
      %{}
    )
  end

  def handle_stop(_event, measurements, metadata, _config) do
    duration_ms = measurements.duration_us / 1000

    :telemetry.execute(
      [:my_app, :request, :duration],
      %{duration: measurements.duration_us},
      %{
        service: metadata.service,
        request_type: metadata.request_type,
        success: metadata.success
      }
    )

    # Or push to your metrics backend directly
    MyApp.Metrics.histogram("phoenix_gen_api.request.duration", duration_ms,
      tags: ["service:#{metadata.service}", "type:#{metadata.request_type}"]
    )
  end
end
```

### Error Rate Tracking

Track error rates and alert on spikes:

```elixir
defmodule MyApp.ErrorTracker do
  @moduledoc """
  Tracks error rates from executor exceptions and failed requests.
  """

  def attach do
    events = [
      [:phoenix_gen_api, :executor, :request, :stop],
      [:phoenix_gen_api, :executor, :request, :exception]
    ]

    PhoenixGenApi.Telemetry.attach_many("error-tracker", events, &__MODULE__.handle/4, %{})
  end

  def handle([:phoenix_gen_api, :executor, :request, :stop], _measurements, metadata, _config) do
    unless metadata.success do
      increment_error(metadata.service, metadata.request_type, "business_error")
    end
  end

  def handle([:phoenix_gen_api, :executor, :request, :exception], _measurements, metadata, _config) do
    increment_error(metadata.service, metadata.request_type, "exception")
  end

  defp increment_error(service, request_type, error_type) do
    MyApp.Metrics.increment("phoenix_gen_api.errors",
      tags: ["service:#{service}", "type:#{request_type}", "error:#{error_type}"]
    )
  end
end
```

### Rate Limit Monitoring

Monitor rate limit activity and alert on excessive rejections:

```elixir
defmodule MyApp.RateLimitMonitor do
  @moduledoc """
  Monitors rate limit events and sends alerts when thresholds are exceeded.
  """

  @alert_threshold 10  # Alert after 10 rate-limited requests per user

  def attach do
    PhoenixGenApi.Telemetry.attach_rate_limiter("rate-limit-monitor", &__MODULE__.handle/4)
  end

  def handle([:phoenix_gen_api, :rate_limiter, :exceeded], measurements, metadata, _config) do
    # Track in your metrics system
    MyApp.Metrics.increment("phoenix_gen_api.rate_limited",
      tags: ["key:#{metadata.key}", "user:#{metadata.user_id}"]
    )

    # Check if we should alert
    count = MyApp.Metrics.count("phoenix_gen_api.rate_limited",
      tags: ["user:#{metadata.user_id}"]
    )

    if count >= @alert_threshold do
      MyApp.Alerts.send(
        "Rate limit spike: user=#{metadata.user_id} has been limited #{count} times"
      )
    end
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok
end
```

### Circuit Breaker Alerts

Get notified when worker pool circuit breakers trip:

```elixir
defmodule MyApp.CircuitBreakerAlert do
  @moduledoc """
  Sends alerts when worker pool circuit breakers open or close.
  """

  def attach do
    events = [
      [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
      [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close]
    ]

    PhoenixGenApi.Telemetry.attach_many("circuit-breaker-alerts", events, &__MODULE__.handle/4)
  end

  def handle(
        [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
        _measurements,
        metadata,
        _config
      ) do
    MyApp.Alerts.send(
      "🚨 Circuit breaker OPEN for pool=#{metadata.pool_name} " <>
      "after #{metadata.consecutive_failures} consecutive failures"
    )
  end

  def handle(
        [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close],
        _measurements,
        metadata,
        _config
      ) do
    MyApp.Alerts.send(
      "✅ Circuit breaker CLOSED for pool=#{metadata.pool_name} — service restored"
    )
  end
end
```

### Distributed Tracing

Integrate with OpenTelemetry or similar tracing systems:

```elixir
defmodule MyApp.TracingIntegration do
  @moduledoc """
  Bridges PhoenixGenApi telemetry events to OpenTelemetry spans.
  """

  def attach do
    PhoenixGenApi.Telemetry.attach_executor("otel-executor", &__MODULE__.handle_executor/4)
  end

  def handle_executor([:phoenix_gen_api, :executor, :request, :start], _measurements, metadata, _config) do
    # Start a new OpenTelemetry span
    OpenTelemetry.Tracer.start_span("phoenix_gen_api.request", %{
      attributes: %{
        "phoenix_gen_api.request_id": metadata.request_id,
        "phoenix_gen_api.service": metadata.service,
        "phoenix_gen_api.request_type": metadata.request_type,
        "phoenix_gen_api.user_id": metadata.user_id
      }
    })
  end

  def handle_executor([:phoenix_gen_api, :executor, :request, :stop], measurements, metadata, _config) do
    # End the span with success status
    OpenTelemetry.Tracer.end_span(%{
      status: if(metadata.success, do: :ok, else: :error),
      attributes: %{
        "phoenix_gen_api.duration_us": measurements.duration_us,
        "phoenix_gen_api.async": metadata.async
      }
    })
  end

  def handle_executor([:phoenix_gen_api, :executor, :request, :exception], measurements, metadata, _config) do
    # End the span with error status
    OpenTelemetry.Tracer.end_span(%{
      status: :error,
      attributes: %{
        "phoenix_gen_api.duration_us": measurements.duration_us,
        "exception.message": metadata.reason,
        "exception.stacktrace": inspect(metadata.stacktrace)
      }
    })
  end

  def handle_executor(_event, _measurements, _metadata, _config), do: :ok
end
```

## Using with Telemetry.Metrics

[Telemetry.Metrics](https://hexdocs.pm/telemetry_metrics/) provides a standard
interface for defining metrics from telemetry events. Define metrics that
PhoenixGenApi events feed into:

```elixir
# In your application or a dedicated module
defmodule MyApp.Metrics do
  def metrics do
    [
      # Executor request duration
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.executor.request.stop.duration_us",
        event_name: [:phoenix_gen_api, :executor, :request, :stop],
        measurement: :duration_us,
        tags: [:service, :request_type, :success],
        unit: {:microsecond, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),

      # Executor exception counter
      Telemetry.Metrics.counter(
        "phoenix_gen_api.executor.request.exception.count",
        event_name: [:phoenix_gen_api, :executor, :request, :exception],
        tags: [:service, :request_type]
      ),

      # Rate limiter exceeded counter
      Telemetry.Metrics.counter(
        "phoenix_gen_api.rate_limiter.exceeded.count",
        event_name: [:phoenix_gen_api, :rate_limiter, :exceeded],
        tags: [:key, :scope]
      ),

      # Worker pool task duration
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.worker_pool.task.stop.duration_us",
        event_name: [:phoenix_gen_api, :worker_pool, :task, :stop],
        measurement: :duration_us,
        tags: [:pool_name]
      ),

      # Worker pool task exception counter
      Telemetry.Metrics.counter(
        "phoenix_gen_api.worker_pool.task.exception.count",
        event_name: [:phoenix_gen_api, :worker_pool, :task, :exception],
        tags: [:pool_name, :kind]
      ),

      # Config cache operations
      Telemetry.Metrics.counter(
        "phoenix_gen_api.config.add.count",
        event_name: [:phoenix_gen_api, :config, :add],
        tags: [:service]
      ),

      Telemetry.Metrics.counter(
        "phoenix_gen_api.config.delete.count",
        event_name: [:phoenix_gen_api, :config, :delete],
        tags: [:service]
      ),

      # Config pull duration
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.config.pull.stop.duration_us",
        event_name: [:phoenix_gen_api, :config, :pull, :stop],
        measurement: :duration_us,
        tags: [:service]
      ),

      # Rate limiter check duration
      Telemetry.Metrics.distribution(
        "phoenix_gen_api.rate_limiter.check.duration_us",
        event_name: [:phoenix_gen_api, :rate_limiter, :check],
        measurement: :duration_us,
        tags: [:service]
      ),

      # Rate limiter cleanup
      Telemetry.Metrics.counter(
        "phoenix_gen_api.rate_limiter.cleanup.cleaned_entries",
        event_name: [:phoenix_gen_api, :rate_limiter, :cleanup],
        measurement: :cleaned_entries
      )
    ]
  end
end
```

## Using with LiveDashboard

[Phoenix LiveDashboard](https://hexdocs.pm/phoenix_live_dashboard/) can display
real-time metrics from PhoenixGenApi events. Add metric definitions to your
LiveDashboard config:

```elixir
# In lib/my_app_web/application.ex or endpoint.ex
live_dashboard "/dashboard",
  metrics: {MyApp.Metrics, :metrics}
```

For metric definitions, see the [Telemetry.Metrics](#using-with-telemetrymetrics)
section above.

## Best Practices

### 1. Use handler IDs that include your application name

Handler IDs must be unique across the entire BEAM instance. Prefix with your
application name to avoid collisions:

```elixir
# Good
PhoenixGenApi.Telemetry.attach_executor("my_app.executor_monitor", &handle/4)

# Bad — may collide with other libraries
PhoenixGenApi.Telemetry.attach_executor("executor_monitor", &handle/4)
```

### 2. Keep handlers fast

Telemetry handlers execute synchronously in the calling process. Slow handlers
will block the process that emitted the event (e.g., the executor process).

```elixir
# Bad — blocking HTTP call in handler
def handle(_event, _measurements, metadata, _config) do
  MyApp.HttpClient.post("https://metrics.example.com", Jason.encode!(metadata))
end

# Good — async dispatch
def handle(_event, _measurements, metadata, _config) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    MyApp.HttpClient.post("https://metrics.example.com", Jason.encode!(metadata))
  end)
end

# Better — use a GenServer/buffer for batching
def handle(_event, _measurements, metadata, _config) do
  MyApp.MetricsBuffer.push(metadata)
end
```

### 3. Use category-specific attach functions

When you only care about one category of events, use the specific attach
function instead of `attach_all/3`:

```elixir
# Good — only executor events
PhoenixGenApi.Telemetry.attach_executor("my-app", &handle/4)

# Wasteful — attaches to all 28 events but only uses 4
PhoenixGenApi.Telemetry.attach_all("my-app", fn event, measurements, metadata, config ->
  case event do
    [:phoenix_gen_api, :executor | _] -> handle(event, measurements, metadata, config)
    _ -> :ok
  end
end)
```

### 4. Clean up handlers in tests

When attaching handlers in tests, always detach them in `on_exit` callbacks:

```elixir
test "emits telemetry on request" do
  :telemetry.attach("test-handler", [:phoenix_gen_api, :executor, :request, :stop], fn _, _, _, _ ->
    # ...
  end, %{})

  on_exit(fn -> :telemetry.detach("test-handler") end)

  # ...
end
```

### 5. Match on specific events in shared handlers

When using a shared handler for multiple events, pattern match on the event name
to handle each appropriately:

```elixir
def handle_event(event, measurements, metadata, _config) do
  case event do
    [:phoenix_gen_api, :executor, :request, :start] ->
      # Handle start
      :ok

    [:phoenix_gen_api, :executor, :request, :stop] ->
      # Handle stop
      :ok

    [:phoenix_gen_api, :executor, :request, :exception] ->
      # Handle exception
      :ok

    _ ->
      :ok
  end
end
```

### 6. Use `:telemetry.span/3` for custom operations

The `PhoenixGenApi.Telemetry.span/3` wrapper emits start/stop/exception events
around any function, following the standard telemetry span convention:

```elixir
result =
  PhoenixGenApi.Telemetry.span(
    [:my_app, :custom_operation],
    %{operation: "data_import"},
    fn ->
      # Your operation here — must return {result, metadata_map}
      data = do_import()
      {:ok, data}
    end
  )
```

The span function:
- Emits `event ++ [:start]` before calling the function
- Emits `event ++ [:stop]` on success (with `duration` measurement)
- Emits `event ++ [:exception]` on exception (then re-raises)

The function must return `{result, metadata}` where `metadata` is a map that
will be merged into the stop event's metadata.

### 7. Discover available events programmatically

Use `list_events/0` to discover all available events at runtime:

```elixir
iex> PhoenixGenApi.Telemetry.list_events()
[
  [:phoenix_gen_api, :executor, :request, :start],
  [:phoenix_gen_api, :executor, :request, :stop],
  [:phoenix_gen_api, :executor, :request, :exception],
  [:phoenix_gen_api, :executor, :retry],
  [:phoenix_gen_api, :rate_limiter, :check],
  [:phoenix_gen_api, :rate_limiter, :exceeded],
  [:phoenix_gen_api, :rate_limiter, :reset],
  [:phoenix_gen_api, :rate_limiter, :cleanup],
  [:phoenix_gen_api, :hook, :before, :start],
  [:phoenix_gen_api, :hook, :before, :stop],
  [:phoenix_gen_api, :hook, :before, :exception],
  [:phoenix_gen_api, :hook, :after, :start],
  [:phoenix_gen_api, :hook, :after, :stop],
  [:phoenix_gen_api, :hook, :after, :exception],
  [:phoenix_gen_api, :worker_pool, :task, :start],
  [:phoenix_gen_api, :worker_pool, :task, :stop],
  [:phoenix_gen_api, :worker_pool, :task, :exception],
  [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
  [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close],
  [:phoenix_gen_api, :config, :pull, :start],
  [:phoenix_gen_api, :config, :pull, :stop],
  [:phoenix_gen_api, :config, :push],
  [:phoenix_gen_api, :config, :add],
  [:phoenix_gen_api, :config, :batch_add],
  [:phoenix_gen_api, :config, :delete],
  [:phoenix_gen_api, :config, :clear],
  [:phoenix_gen_api, :config, :disable],
  [:phoenix_gen_api, :config, :enable]
]
```
