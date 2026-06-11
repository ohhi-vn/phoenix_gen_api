defmodule PhoenixGenApi do
  @moduledoc """
  PhoenixGenApi is a framework for building distributed API systems with Phoenix.

  This library provides a comprehensive solution for handling API requests with support
  for multiple execution modes (sync, async, streaming), distributed node selection,
  permission checking, and automatic argument validation.

  ## Features

  - **Multiple Execution Modes**: Support for synchronous, asynchronous, streaming, and fire-and-forget requests
  - **Distributed Execution**: Execute functions on remote nodes with automatic node selection
  - **Node Selection Strategies**: Random, hash-based, round-robin, and custom selection strategies
  - **Automatic Argument Validation**: Type checking and conversion for request arguments
  - **Permission Control**: Built-in permission checking for requests
  - **Streaming Support**: Handle long-running operations with streaming responses
  - **Configuration Caching**: Efficient caching of function configurations with automatic updates
  - **Configuration Push**: Remote nodes can actively push their service and function configs to the gateway
  - **Rate Limiting**: Global and per-API rate limiting with sliding window algorithm
  - **Relay Messages**: Group-based message relaying with public, private, and strict_private group types
  - **Diagnostics**: Runtime health checks, statistics, debug reports, and admin-gated tracing utilities

  ## Architecture

  The library consists of several key components:

  - `PhoenixGenApi.Executor` - Core execution engine for processing requests
  - `PhoenixGenApi.ConfigDb` - Caches function configurations for fast lookup
  - `PhoenixGenApi.ConfigPuller` - Pulls and updates configurations from remote services
  - `PhoenixGenApi.ConfigReceiver` - Receives pushed configurations from remote nodes (server-side)
  - `PhoenixGenApi.ConfigPusher` - Pushes configurations to the gateway node (client-side)
  - `PhoenixGenApi.NodeSelector` - Selects target nodes based on configured strategies
  - `PhoenixGenApi.Permission` - Handles permission checking for requests
  - `PhoenixGenApi.ArgumentHandler` - Validates and converts request arguments
  - `PhoenixGenApi.StreamCall` - Manages streaming function calls
  - `PhoenixGenApi.RateLimiter` - Rate limiting for global and per-API requests
  - `PhoenixGenApi.Relay` - Group-based message relaying (public, private, strict_private)
  - `PhoenixGenApi.Diagnostics` - Runtime health, statistics, debug, and tracing utilities

  ## Usage Example

  ### Basic Setup

  First, define your function configurations:

      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: ["user@node1", "user@node2"],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {UserService, :get_user, []},
        arg_types: %{"user_id" => :string},
        arg_orders: ["user_id"],
        response_type: :sync,
        check_permission: {:arg, "user_id"},
        request_info: false
      }

      # Add configuration to cache
      PhoenixGenApi.ConfigDb.add(config)

  ### Execute Requests
      use PhoenixGenApi

      # Create a request
      request = %PhoenixGenApi.Structs.Request{
        request_id: "req_123",
        request_type: "get_user",
        user_id: "user_456",
        device_id: "device_789",
        args: %{"user_id" => "user_123"}
      }

      # Execute the request
      response = PhoenixGenApi.Executor.execute!(request)

  ### Streaming Requests

  For long-running operations, use streaming mode:

      stream_config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "process_data",
        service: "processing_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: :infinity,
        mfa: {DataProcessor, :process_large_dataset, []},
        arg_types: %{"dataset_id" => :string},
        arg_orders: ["dataset_id"],
        response_type: :stream,
        check_permission: false,
        request_info: true
      }

      # The streaming function should send results using StreamHelper:
      # StreamHelper.send_result(stream, chunk_data)
      # StreamHelper.send_last_result(stream, final_data)
      # Or: StreamHelper.send_complete(stream)

  ## Channel Options

  When using `use PhoenixGenApi` in a channel, the following options are available:

  - `:event` (default: `"phoenix_gen_api"`) — the event name to handle.
  - `:override_user_id` (default: `true`) — when `true`, the `user_id` from
    `socket.assigns` is injected into the request payload, but **only** when
    `socket.assigns.user_id` is a verified non-empty binary. This prevents a
    client-supplied `user_id` from overriding the server-side value. The
    `user_id` in assigns must be set by a verified authentication step in
    `Phoenix.Socket.connect/3`, never from client payload.
  - `:require_verified_user_id` (default: `true`) — when `true`, requests are
    rejected immediately with `"Authentication required"` if
    `socket.assigns.user_id` is nil or empty. This prevents unauthenticated
    requests from reaching permission checks or function execution. Set to
    `false` for public endpoints that use `check_permission: false`.

    **Security note**: Setting this to `false` disables the early rejection of
    unauthenticated requests. Only do this for channels that serve public data.

  ## Configuration

  Add to your `config.exs`:

      config :phoenix_gen_api, :gen_api,
        pull_timeout: 5_000,
        pull_interval: 30_000,
        detail_error: false,
        service_configs: [
          %{
            service: "user_service",
            nodes: ["user@node1", "user@node2"],
            module: "UserService",
            function: "get_config",
            args: []
          }
        ]

  ## Rate Limiting Configuration

  Configure rate limits in your `config.exs`:

      config :phoenix_gen_api, :rate_limiter,
        enabled: true,
        fail_open: true,
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

  ## Learn More

  For detailed information about specific components, see:

  - `PhoenixGenApi.Executor` - Request execution
  - `PhoenixGenApi.Structs.FunConfig` - Function configuration
  - `PhoenixGenApi.Structs.Request` - Request structure
  - `PhoenixGenApi.Structs.Response` - Response structure
  - `PhoenixGenApi.NodeSelector` - Node selection strategies
  """

  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Diagnostics

  @spec stop_stream(pid()) :: :ok
  @doc """
  Stops an active streaming call.

  This function gracefully terminates a streaming call process and sends a completion
  message to the receiver. The stream call process is identified by its PID.

  ## Parameters

    - `stream_pid` - The PID of the streaming call process to stop

  ## Returns

    - `:ok` - The stop signal was sent successfully

  ## Examples

      # Start a stream
      {:ok, stream_pid} = StreamCall.start_link(%{
        request: request,
        fun_config: config,
        receiver: self()
      })

      # Later, stop the stream
      PhoenixGenApi.stop_stream(stream_pid)

      # Receive the completion message
      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      end

  ## Notes

  - The stream call will send a completion response to its receiver before terminating
  - This does not notify the data generator process; it only stops the stream relay
  - If you need to stop the data generation itself, handle that in your generator function
  """
  def stop_stream(request_id) do
    StreamCall.stop(request_id)
  end

  @doc """
  Checks rate limit for a request.

  This function checks both global and per-API rate limits. It is automatically
  called during request execution, but can also be called manually for custom
  rate limiting logic.

  ## Parameters

    - `request` - The `Request` struct to check

  ## Returns

    - `:ok` - Request is within all rate limits
    - `{:error, :rate_limited, details}` - Request exceeds a rate limit

  ## Examples

      request = %Request{user_id: "user_123", service: "my_service", request_type: "my_api"}

      case PhoenixGenApi.check_rate_limit(request) do
        :ok ->
          # Proceed with execution

        {:error, :rate_limited, details} ->
          # Handle rate limit exceeded
      end
  """
  @spec check_rate_limit(PhoenixGenApi.Structs.Request.t()) ::
          :ok | {:error, :rate_limited, map()}
  def check_rate_limit(request) do
    RateLimiter.check_rate_limit(request)
  end

  @doc """
  Resets rate limit counters for a specific key.

  ## Parameters

    - `key_value` - The key value to reset (e.g., user ID)
    - `scope` - Either `:global` or `{service, request_type}` tuple
    - `rate_limit_key` - The type of key (`:user_id`, `:device_id`, etc.)

  ## Returns

    - `:ok` - Counters were reset

  ## Examples

      # Reset all rate limits for a user
      PhoenixGenApi.reset_rate_limit("user_123", :global, :user_id)

      # Reset API-specific rate limit
      PhoenixGenApi.reset_rate_limit("user_123", {"my_service", "my_api"}, :user_id)
  """
  @spec reset_rate_limit(
          String.t(),
          :global | {String.t() | atom(), String.t()},
          atom() | String.t()
        ) ::
          :ok
  def reset_rate_limit(key_value, scope, rate_limit_key) do
    RateLimiter.reset_rate_limit(key_value, scope, rate_limit_key)
  end

  @doc """
  Gets current rate limit status for a key.

  ## Returns

    A list of maps with current usage information for all applicable rate limits.
  """
  @spec get_rate_limit_status(
          String.t(),
          :global | {String.t() | atom(), String.t()},
          atom() | String.t()
        ) :: map()
  def get_rate_limit_status(key_value, scope, rate_limit_key) do
    RateLimiter.get_rate_limit_status(key_value, scope, rate_limit_key)
  end

  @doc """
  Updates rate limit configuration at runtime.

  ## Parameters

    - `config` - A map with `:global_limits` and/or `:api_limits` keys

  ## Returns

    - `:ok` - Configuration was updated

  ## Examples

      PhoenixGenApi.update_rate_limit_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 2000, window_ms: 60_000}
        ]
      })
  """
  @spec update_rate_limit_config(map()) :: :ok
  def update_rate_limit_config(config) do
    RateLimiter.update_config(config)
  end

  @doc """
  Gets all configured rate limits.

  ## Returns

    A map with `:global` and `:api` keys containing the configured limits.
  """
  @spec get_rate_limit_config() :: %{global: list(), api: list()}
  def get_rate_limit_config() do
    RateLimiter.get_configured_limits()
  end

  @doc """
  Gets the current global rate limits (may differ from config.exs if changed at runtime).

  ## Returns

    A list of global rate limit maps.

  ## Examples

      PhoenixGenApi.get_global_limits()
      # => [%{key: :user_id, max_requests: 2000, window_ms: 60_000}]
  """
  @spec get_global_limits() :: [map()]
  def get_global_limits() do
    RateLimiter.get_global_limits()
  end

  @doc """
  Sets (replaces) all global rate limits at runtime.

  ## Parameters

    - `limits` - A list of global rate limit maps, each with:
      - `:key` - The rate limit key (`:user_id`, `:device_id`, `:ip_address`, or custom string)
      - `:max_requests` - Maximum requests allowed in the window
      - `:window_ms` - Window duration in milliseconds

  ## Returns

    - `:ok` - Limits were updated

  ## Examples

      PhoenixGenApi.set_global_limits([
        %{key: :user_id, max_requests: 2000, window_ms: 60_000},
        %{key: :device_id, max_requests: 10000, window_ms: 60_000}
      ])
  """
  @spec set_global_limits([map()]) :: :ok
  def set_global_limits(limits) when is_list(limits) do
    RateLimiter.set_global_limits(limits)
  end

  @doc """
  Adds a single global rate limit at runtime.

  If a limit with the same `:key` already exists, it will be replaced.

  ## Parameters

    - `limit` - A map with `:key`, `:max_requests`, and `:window_ms`

  ## Returns

    - `:ok` - Limit was added

  ## Examples

      PhoenixGenApi.add_global_limit(%{
        key: :ip_address,
        max_requests: 100,
        window_ms: 60_000
      })
  """
  @spec add_global_limit(map()) :: :ok
  def add_global_limit(limit) when is_map(limit) do
    RateLimiter.add_global_limit(limit)
  end

  @doc """
  Removes a global rate limit by key at runtime.

  ## Parameters

    - `key` - The rate limit key to remove (`:user_id`, `:device_id`, etc.)

  ## Returns

    - `:ok` - Limit was removed (or didn't exist)

  ## Examples

      PhoenixGenApi.remove_global_limit(:ip_address)
  """
  @spec remove_global_limit(atom() | String.t()) :: :ok
  def remove_global_limit(key) do
    RateLimiter.remove_global_limit(key)
  end

  @doc """
  Attaches a telemetry handler to all PhoenixGenApi events.

  This is a convenience function that attaches handlers to both executor and
  rate limiter events with a single call.

  ## Events

  ### Executor Events
  - `[:phoenix_gen_api, :executor, :request, :start]`
  - `[:phoenix_gen_api, :executor, :request, :stop]`
  - `[:phoenix_gen_api, :executor, :request, :exception]`

  ### Rate Limiter Events
  - `[:phoenix_gen_api, :rate_limiter, :check]`
  - `[:phoenix_gen_api, :rate_limiter, :exceeded]`
  - `[:phoenix_gen_api, :rate_limiter, :reset]`
  - `[:phoenix_gen_api, :rate_limiter, :cleanup]`

  ## Parameters

    - `handler_id` - A unique string identifier for the handler
    - `function` - A 4-arity function: fn(event, measurements, metadata, config) -> any end
    - `config` - Optional configuration map passed to the handler (default: %{})

  ## Examples

      # Attach a simple logging handler
      PhoenixGenApi.attach_telemetry("my-app", fn event, measurements, metadata, _config ->
        ...
      end)

      # Attach with custom config
      PhoenixGenApi.attach_telemetry("metrics", &MyApp.Metrics.handle_event/4, %{prefix: "phoenix_gen_api"})
  """
  @spec attach_telemetry(String.t(), function(), map()) :: :ok
  def attach_telemetry(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    PhoenixGenApi.Executor.attach_telemetry(handler_id, function, config)
    PhoenixGenApi.RateLimiter.attach_telemetry(handler_id, function, config)
    :ok
  end

  @doc """
  Detaches all telemetry handlers with the given ID.

  ## Parameters

    - `handler_id` - The handler ID used when attaching

  ## Examples

      PhoenixGenApi.detach_telemetry("my-app")
  """
  @spec detach_telemetry(String.t()) :: :ok
  def detach_telemetry(handler_id) when is_binary(handler_id) do
    PhoenixGenApi.Executor.detach_telemetry(handler_id)
    PhoenixGenApi.RateLimiter.detach_telemetry(handler_id)
    :ok
  end

  # ============================================================================
  # Shell Helper Functions (for easy inspection in IEx)
  # ============================================================================

  @doc """
  [Shell Helper] Quick view of rate limit status for a user.

  ## Usage in IEx

      iex> PhoenixGenApi.rl_status("user_123")
  """
  def rl_status(user_id) when is_binary(user_id) do
    IO.puts("\n=== Rate Limit Status for #{user_id} ===\n")

    IO.puts("Global Limits:")

    get_rate_limit_status(user_id, :global, :user_id)
    |> Enum.each(fn info ->
      IO.puts(
        "  Scope: #{inspect(info.scope)} | Used: #{info.current_requests}/#{info.max_requests} | Remaining: #{info.remaining}"
      )
    end)

    IO.puts("\nAPI Limits:")

    get_rate_limit_config().api
    |> Enum.filter(&(&1.key == :user_id))
    |> Enum.each(fn limit ->
      scope = {limit.service, limit.request_type}
      status = get_rate_limit_status(user_id, scope, :user_id)

      Enum.each(status, fn info ->
        IO.puts(
          "  #{limit.service}/#{limit.request_type} | Used: #{info.current_requests}/#{info.max_requests} | Remaining: #{info.remaining}"
        )
      end)
    end)

    :ok
  end

  @doc """
  [Shell Helper] Quick view and management of global rate limits.

  ## Usage in IEx

      # View current global limits
      iex> PhoenixGenApi.rl_global()

      # Set new global limits
      iex> PhoenixGenApi.rl_global([%{key: :user_id, max_requests: 2000, window_ms: 60_000}])

      # Add a single limit
      iex> PhoenixGenApi.rl_global(:add, %{key: :ip_address, max_requests: 100, window_ms: 60_000})

      # Remove a limit by key
      iex> PhoenixGenApi.rl_global(:remove, :ip_address)
  """
  def rl_global() do
    IO.puts("\n=== Global Rate Limits ===\n")

    get_global_limits()
    |> Enum.each(fn l ->
      IO.puts("  Key: #{inspect(l.key)} | Max: #{l.max_requests} | Window: #{l.window_ms}ms")
    end)

    :ok
  end

  def rl_global(limits) when is_list(limits) do
    set_global_limits(limits)
    IO.puts("\nGlobal rate limits updated.\n")
    rl_global()
  end

  def rl_global(:add, limit) when is_map(limit) do
    add_global_limit(limit)
    IO.puts("\nGlobal rate limit added/updated: #{inspect(limit)}\n")
    rl_global()
  end

  def rl_global(:remove, key) do
    remove_global_limit(key)
    IO.puts("\nGlobal rate limit removed for key: #{inspect(key)}\n")
    rl_global()
  end

  @doc """
  [Shell Helper] Quick view of current rate limit configuration.

  ## Usage in IEx

      iex> PhoenixGenApi.rl_config()
  """
  def rl_config() do
    config = get_rate_limit_config()
    IO.puts("\n=== Rate Limit Configuration ===\n")
    IO.puts("Global Limits:")

    Enum.each(config.global, fn l ->
      IO.puts("  Key: #{inspect(l.key)} | Max: #{l.max_requests} | Window: #{l.window_ms}ms")
    end)

    IO.puts("\nAPI Limits:")

    Enum.each(config.api, fn l ->
      IO.puts(
        "  #{l.service}/#{l.request_type} | Key: #{inspect(l.key)} | Max: #{l.max_requests} | Window: #{l.window_ms}ms"
      )
    end)

    :ok
  end

  @doc """
  [Shell Helper] Quick view of ConfigDb cache status.

  ## Usage in IEx

      iex> PhoenixGenApi.cache_status()
  """
  def cache_status() do
    IO.puts("\n=== ConfigDb Cache Status ===\n")
    IO.puts("Total cached configs: #{PhoenixGenApi.ConfigDb.count()}")
    IO.puts("Services: #{inspect(PhoenixGenApi.ConfigDb.get_all_services())}")
    :ok
  end

  @doc """
  [Shell Helper] Quick view of Worker Pool status.

  ## Usage in IEx

      iex> PhoenixGenApi.pool_status()
  """
  def pool_status() do
    IO.puts("\n=== Worker Pool Status ===\n")
    async_status = PhoenixGenApi.WorkerPool.status(:async_pool)
    stream_status = PhoenixGenApi.WorkerPool.status(:stream_pool)

    IO.puts("Async Pool:")

    IO.puts(
      "  Idle: #{async_status.idle_workers} | Busy: #{async_status.busy_workers} | Queued: #{async_status.queued_tasks}"
    )

    IO.puts("  Circuit Open: #{async_status.circuit_open}")

    IO.puts("\nStream Pool:")

    IO.puts(
      "  Idle: #{stream_status.idle_workers} | Busy: #{stream_status.busy_workers} | Queued: #{stream_status.queued_tasks}"
    )

    IO.puts("  Circuit Open: #{stream_status.circuit_open}")
    :ok
  end

  @doc """
  [Shell Helper] Print a formatted health check summary to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.health_print()
      iex> PhoenixGenApi.health_print(max_memory_bytes: 100_000_000)
  """
  def health_print(opts \\ []) do
    report = Diagnostics.health_check(opts)

    status_icon = fn
      :ok -> "✅"
      :degraded -> "⚠️ "
      :error -> "❌"
    end

    IO.puts("\n=== PhoenixGenApi Health Check ===")
    IO.puts("Node: #{report.node}")
    IO.puts("Status: #{status_icon.(report.status)} #{report.status}")
    IO.puts("Checked at: #{DateTime.from_unix!(report.checked_at_ms, :millisecond)}")

    vm = report.checks.vm
    IO.puts("\n--- VM ---")
    IO.puts("  Status:      #{status_icon.(vm.status)} #{vm.status}")
    IO.puts("  Processes:   #{vm.process_count} / #{vm.process_limit}")
    IO.puts("  Schedulers:  #{vm.schedulers_online} / #{vm.schedulers}")
    IO.puts("  Memory:      #{format_bytes(vm.memory[:total])} total")
    IO.puts("    Processes: #{format_bytes(vm.memory[:processes])}")
    IO.puts("    System:    #{format_bytes(vm.memory[:system])}")
    IO.puts("  Uptime:      #{format_uptime(vm.uptime)}")

    node = report.checks.node
    IO.puts("\n--- Node ---")
    IO.puts("  Self:        #{node.node}")
    IO.puts("  Alive:       #{node.alive?}")
    IO.puts("  Connected:   #{inspect(node.connected_nodes)}")

    pga = report.checks.phoenix_gen_api
    IO.puts("\n--- PhoenixGenApi ---")
    IO.puts("  Status:      #{status_icon.(pga.status)} #{pga.status}")
    IO.puts("  Mode:        #{pga.mode}")

    case pga do
      %{checks: checks} ->
        IO.puts("  Processes:")

        Enum.each(checks, fn {name, check} ->
          icon = if check.status == :ok, do: "✅", else: "❌"
          pid_str = if check[:pid], do: "#{inspect(check[:pid])}", else: "N/A"
          extra = if check[:instance_count], do: "  instances=#{check[:instance_count]}", else: ""
          IO.puts("    #{icon} #{name}  pid=#{pid_str}#{extra}")
        end)

      %{} ->
        :ok
    end

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print formatted VM and PhoenixGenApi statistics to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.stats_print()
  """
  def stats_print() do
    stats = Diagnostics.statistics()

    IO.puts("\n=== PhoenixGenApi Statistics ===")
    IO.puts("Node: #{stats.node}")
    IO.puts("Collected at: #{DateTime.from_unix!(stats.collected_at_ms, :millisecond)}")

    vm = stats.vm
    IO.puts("\n--- VM ---")
    IO.puts("  Processes:     #{vm.process_count} / #{vm.process_limit}")
    IO.puts("  Ports:         #{vm.port_count}")
    IO.puts("  ETS tables:    #{vm.ets_count}")
    IO.puts("  Schedulers:    #{vm.schedulers_online} / #{vm.schedulers}")
    IO.puts("  Memory:        #{format_bytes(vm.memory[:total])} total")

    IO.puts(
      "    Processes:   #{format_bytes(vm.memory[:processes])} (#{format_bytes(vm.memory[:processes_used])} used)"
    )

    IO.puts("    System:      #{format_bytes(vm.memory[:system])}")

    IO.puts(
      "    Atoms:       #{format_bytes(vm.memory[:atom])} (#{format_bytes(vm.memory[:atom_used])} used)"
    )

    IO.puts("    Binary:      #{format_bytes(vm.memory[:binary])}")
    IO.puts("    Code:        #{format_bytes(vm.memory[:code])}")
    IO.puts("    ETS:         #{format_bytes(vm.memory[:ets])}")

    {red_total, red_since} = vm.reductions
    IO.puts("  Reductions:    #{red_total} total, #{red_since} since last call")

    {gc_count, gc_words, _} = vm.garbage_collection
    IO.puts("  GC:            #{gc_count} collections, #{gc_words} words reclaimed")

    {cs_count, _} = vm.context_switches
    IO.puts("  Context sw:    #{cs_count}")
    IO.puts("  Uptime:        #{format_uptime(vm.uptime)}")

    if vm.scheduler_wall_time && vm.scheduler_wall_time != :undefined do
      IO.puts("  Scheduler wall time:")

      Enum.each(vm.scheduler_wall_time, fn {id, active, total} ->
        pct = if total > 0, do: Float.round(active / total * 100, 1), else: 0.0
        IO.puts("    Scheduler #{id}: #{pct}% active (#{active}ms / #{total}ms)")
      end)
    end

    pga = stats.phoenix_gen_api
    IO.puts("\n--- PhoenixGenApi ---")
    IO.puts("  Client mode:   #{pga.client_mode}")
    IO.puts("  Telemetry events: #{pga.telemetry_events}")

    case pga do
      %{config_db: db} ->
        IO.puts("\n  ConfigDb:")
        IO.puts("    Status:    #{db.status}")
        IO.puts("    Count:     #{db.count}")
        IO.puts("    Services:  #{inspect(db.services)}")

      %{} ->
        :ok
    end

    case pga do
      %{rate_limiter: rl} ->
        IO.puts("\n  Rate Limiter:")
        IO.puts("    Status:    #{rl.status}")

        if rl.data do
          IO.puts("    Instances: #{length(rl.data.instances)}")
        end

      %{} ->
        :ok
    end

    case pga do
      %{worker_pool: worker_pool} ->
        IO.puts("\n  Worker Pools:")

        Enum.each(worker_pool, fn {name, pool} ->
          IO.puts("    #{name}:")
          IO.puts("      Status:   #{pool.status}")

          if pool.data do
            d = pool.data

            IO.puts(
              "      Idle: #{d.idle_workers}  Busy: #{d.busy_workers}  Queued: #{d.queued_tasks}"
            )

            IO.puts(
              "      Circuit: #{d.circuit_open}  Executed: #{d.total_tasks_executed}  Failed: #{d.total_tasks_failed}"
            )
          end
        end)

      %{} ->
        :ok
    end

    case pga do
      %{relay: relay} ->
        IO.puts("\n  Relay:")
        IO.puts("    Status:  #{relay.status}")

        if relay.data do
          IO.puts("    Groups:  #{relay.data.group_count}")
          IO.puts("    Monitored memberships: #{relay.data.monitored_memberships}")
        end

      %{} ->
        :ok
    end

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print a formatted debug report to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.debug_print(process_limit: 10)
  """
  def debug_print(opts \\ []) do
    report = Diagnostics.debug_report(opts)
    limit = Keyword.get(opts, :process_limit, 20)

    IO.puts("\n=== Debug Report ===")
    IO.puts("Node: #{report.node}")
    IO.puts("Collected at: #{DateTime.from_unix!(report.collected_at_ms, :millisecond)}")

    IO.puts("\n--- Top #{limit} Processes by Memory ---")

    IO.puts(
      String.pad_trailing("PID", 15) <>
        String.pad_trailing("Name", 30) <> String.pad_trailing("Memory", 12) <> "Status"
    )

    IO.puts(String.duplicate("-", 70))

    Enum.each(report.processes, fn p ->
      pid_str = String.pad_trailing(inspect(p.pid), 15)
      name_str = String.pad_trailing(inspect(p.registered_name || :unnamed), 30)
      mem_str = String.pad_trailing(format_bytes(p.memory), 12)
      status_str = inspect(p.status)
      IO.puts(pid_str <> name_str <> mem_str <> status_str)
    end)

    IO.puts("\n--- ETS Tables ---")

    Enum.each(report.ets_tables, fn {name, info} ->
      if info[:exists] do
        size = Map.get(info, :size, "?")
        mem_words = Map.get(info, :memory, "?")
        IO.puts("  #{name}: size=#{size} memory=#{mem_words} words")
      else
        IO.puts("  #{name}: (not found)")
      end
    end)

    IO.puts("\n--- Trace ---")
    IO.puts("  Control word: #{report.trace.trace_control_word}")

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print a formatted call flow trace to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.call_flow_print("user_service", "get_user")
      iex> PhoenixGenApi.call_flow_print("user_service", "get_user", "1.0.0")
  """
  def call_flow_print(service, request_type, version \\ nil) do
    flow = Diagnostics.call_flow(service, request_type, version)

    IO.puts("\n=== Call Flow: #{service}/#{request_type} ===")

    case flow do
      %{error: error} ->
        IO.puts("❌ Config not found: #{inspect(error)}")
        IO.puts("")
        :ok

      %{service: service_name, request_type: request_type_name, version: version} ->
        IO.puts("Service:      #{service_name}")
        IO.puts("Request Type: #{request_type_name}")
        IO.puts("Version:      #{inspect(version)}")
        IO.puts("Response:     #{flow.response_type}")
        IO.puts("Local:        #{flow.local?}")
        IO.puts("Node Mode:    #{flow.choose_node_mode}")
        IO.puts("Timeout:      #{flow.timeout}ms")
        IO.puts("MFA:          #{inspect(flow.mfa)}")

        IO.puts("\n--- Nodes ---")
        IO.puts("  All:         #{inspect(flow.nodes)}")
        IO.puts("  Reachable:   #{inspect(flow.reachable_nodes)}")

        if flow.unreachable_nodes != [] do
          IO.puts("  ❌ Unreachable: #{inspect(flow.unreachable_nodes)}")
        end

        IO.puts("\n--- Rate Limits ---")

        if flow.rate_limit.global != [] do
          IO.puts("  Global:")

          Enum.each(flow.rate_limit.global, fn l ->
            IO.puts("    #{l.key}: #{l.max_requests} req / #{l.window_ms}ms")
          end)
        else
          IO.puts("  Global: (none)")
        end

        if flow.rate_limit.api != [] do
          IO.puts("  API:")

          Enum.each(flow.rate_limit.api, fn l ->
            IO.puts("    #{l.key}: #{l.max_requests} req / #{l.window_ms}ms")
          end)
        else
          IO.puts("  API: (none)")
        end

        IO.puts("\n--- Permission ---")
        IO.puts("  #{flow.permission.description}")

        IO.puts("\n--- Hooks ---")
        IO.puts("  Before: #{flow.hooks.before_execute.description}")
        IO.puts("  After:  #{flow.hooks.after_execute.description}")

        IO.puts("\n--- Retry ---")
        IO.puts("  #{flow.retry.description}")

        IO.puts("\n--- Execution Steps ---")

        Enum.with_index(flow.steps, 1)
        |> Enum.each(fn {step, idx} ->
          IO.puts("  #{idx}. [#{step.phase}] #{step.desc}")
        end)

        IO.puts("")
        :ok
    end
  end

  @doc """
  [Shell Helper] Print a formatted cluster topology view to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.cluster_print()
  """
  def cluster_print() do
    view = Diagnostics.cluster_view()

    IO.puts("\n=== Cluster View ===")
    IO.puts("Self: #{view.self}")
    IO.puts("Connected nodes (#{view.connected_count}): #{inspect(view.connected)}")

    IO.puts("\n--- Registered Processes ---")

    Enum.each(view.registered_processes, fn {node, names} ->
      IO.puts("  #{node}: #{length(names)} processes")

      Enum.each(names, fn name ->
        IO.puts("    - #{name}")
      end)
    end)

    IO.puts("\n--- PhoenixGenApi Services by Node ---")

    Enum.each(view.phoenix_gen_api_services, fn {node, services} ->
      IO.puts("  #{node}: #{inspect(services)}")
    end)

    IO.puts("\n--- Node Selection Strategies ---")
    IO.puts("  #{Enum.join(Enum.map(view.node_selection.strategies, &inspect/1), ", ")}")
    IO.puts("  #{view.node_selection.description}")

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print a formatted list of all registered call flows.

  ## Usage in IEx

      iex> PhoenixGenApi.flows_print()
      iex> PhoenixGenApi.flows_print(include_disabled: true)
  """
  def flows_print(opts \\ []) do
    flows = Diagnostics.list_call_flows(opts)

    IO.puts("\n=== Registered Call Flows ===")
    IO.puts("Total: #{length(flows)}")

    if flows == [] do
      IO.puts("  (no registered configs)")
    else
      header =
        String.pad_trailing("Service", 25) <>
          String.pad_trailing("Request Type", 25) <>
          String.pad_trailing("Version", 12) <> String.pad_trailing("Local", 8) <> "Nodes"

      IO.puts("\n" <> header)
      IO.puts(String.duplicate("-", 90))

      Enum.each(flows, fn flow ->
        status = if flow.disabled, do: " [DISABLED]", else: ""
        service = String.pad_trailing(inspect(flow.service), 25)
        req_type = String.pad_trailing(inspect(flow.request_type), 25)
        version = String.pad_trailing(inspect(flow.version), 12)
        mode = String.pad_trailing(to_string(flow.local?), 8)
        nodes = inspect(flow.nodes)
        IO.puts(service <> req_type <> version <> mode <> nodes <> status)
      end)
    end

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print a formatted request inspection to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.inspect_print(%{service: "user_service", request_type: "get_user"})
  """
  def inspect_print(request) do
    plan = Diagnostics.inspect_request(request)

    IO.puts("\n=== Request Inspection ===")

    if plan.request do
      r = plan.request
      IO.puts("Service:      #{inspect(r.service)}")
      IO.puts("Request Type: #{inspect(r.request_type)}")
      IO.puts("Version:      #{inspect(r.version)}")
      IO.puts("User ID:      #{inspect(r.user_id)}")
      IO.puts("Device ID:    #{inspect(r.device_id)}")
      IO.puts("Request ID:   #{inspect(r.request_id)}")
    end

    if plan.error do
      IO.puts("\n❌ Config not found: #{inspect(plan.error)}")
    else
      IO.puts("\n--- Execution Plan ---")

      Enum.with_index(plan.steps, 1)
      |> Enum.each(fn {step, idx} ->
        IO.puts("  #{idx}. [#{step.phase}] #{step.desc}")
      end)
    end

    IO.puts("")
    :ok
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private formatters
  # ──────────────────────────────────────────────────────────────────────

  defp format_bytes(bytes) when is_integer(bytes) when bytes < 1024 do
    "#{bytes} B"
  end

  defp format_bytes(bytes) when is_integer(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes) when bytes < 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
  end

  defp format_bytes(_), do: "?"

  defp format_uptime({ms, _}) when is_integer(ms) do
    seconds = div(ms, 1000)
    hours = div(seconds, 3600)
    minutes = rem(div(seconds, 60), 60)
    secs = rem(seconds, 60)
    "#{hours}h #{minutes}m #{secs}s"
  end

  defp format_uptime(_), do: "?"

  @doc """
  Returns a runtime health check for the VM, distribution, and PhoenixGenApi processes.

  Delegates to `PhoenixGenApi.Diagnostics.health_check/1`.
  """
  @spec health_check(keyword()) :: map()
  def health_check(opts \\ []) do
    PhoenixGenApi.Diagnostics.health_check(opts)
  end

  @doc """
  Returns runtime VM and PhoenixGenApi statistics.

  Delegates to `PhoenixGenApi.Diagnostics.statistics/1`.
  """
  @spec statistics(keyword()) :: map()
  def statistics(opts \\ []) do
    PhoenixGenApi.Diagnostics.statistics(opts)
  end

  @doc """
  Returns a debug-oriented runtime report.

  Delegates to `PhoenixGenApi.Diagnostics.debug_report/1`.
  """
  @spec debug_report(keyword()) :: map()
  def debug_report(opts \\ []) do
    PhoenixGenApi.Diagnostics.debug_report(opts)
  end

  @doc """
  Enables legacy Erlang tracing for processes or ports.

  Requires the `:enable_tracing` admin action.
  """
  @spec trace_processes(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace_processes(targets, opts \\ []) do
    PhoenixGenApi.Diagnostics.trace_processes(targets, opts)
  end

  @doc """
  Enables call tracing for specific MFAs.

  Requires the `:enable_tracing` admin action.
  """
  @spec trace_functions(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace_functions(mfas, opts \\ []) do
    PhoenixGenApi.Diagnostics.trace_functions(mfas, opts)
  end

  @doc """
  Disables legacy Erlang tracing for processes or ports.

  Requires the `:disable_tracing` admin action.
  """
  @spec stop_trace(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop_trace(targets \\ :all, opts \\ []) do
    PhoenixGenApi.Diagnostics.stop_trace(targets, opts)
  end

  @doc """
  Disables call tracing for specific MFAs.

  Requires the `:disable_tracing` admin action.
  """
  @spec stop_trace_functions(term()) :: {:ok, map()} | {:error, term()}
  def stop_trace_functions(mfas \\ :all) do
    PhoenixGenApi.Diagnostics.stop_trace_functions(mfas)
  end

  @doc """
  Returns a small trace status snapshot.
  """
  @spec trace_status() :: map()
  def trace_status do
    PhoenixGenApi.Diagnostics.trace_status()
  end

  @doc """
  [Shell Helper] Traces the call flow for a service/request_type from the
  gateway to its target nodes.

  ## Usage in IEx

      iex> PhoenixGenApi.call_flow("user_service", "get_user")
  """
  @spec call_flow(String.t() | atom(), String.t(), String.t() | nil) :: map()
  def call_flow(service, request_type, version \\ nil) do
    PhoenixGenApi.Diagnostics.call_flow(service, request_type, version)
  end

  @doc """
  [Shell Helper] Inspects a request and returns its full execution plan.

  ## Usage in IEx

      iex> PhoenixGenApi.inspect_request(%{service: "user_service", request_type: "get_user"})
  """
  @spec inspect_request(map()) :: map()
  def inspect_request(request) do
    PhoenixGenApi.Diagnostics.inspect_request(request)
  end

  @doc """
  [Shell Helper] Returns the cluster topology view from this node.

  ## Usage in IEx

      iex> PhoenixGenApi.cluster_view()
  """
  @spec cluster_view() :: map()
  def cluster_view do
    PhoenixGenApi.Diagnostics.cluster_view()
  end

  @doc """
  [Shell Helper] Lists all registered call flows across all services.

  ## Usage in IEx

      iex> PhoenixGenApi.list_call_flows()
      iex> PhoenixGenApi.list_call_flows(include_disabled: true)
  """
  @spec list_call_flows(keyword()) :: [map()]
  def list_call_flows(opts \\ []) do
    PhoenixGenApi.Diagnostics.list_call_flows(opts)
  end

  @doc """
  Pushes a `PushConfig` to this server node.

  This is the server-side API for receiving pushed configs from remote nodes.
  Remote nodes should use `ConfigPusher.push/2` or `ConfigPusher.push_on_startup/3`
  instead, which make RPC calls to this function.

  ## Parameters

    - `push_config` - A `%PushConfig{}` struct or map that can be decoded into one
    - `opts` - Options keyword list:
      - `:force` - Force push even if version matches (default: `false`)

  ## Returns

    - `{:ok, :accepted}` - New configs were stored successfully
    - `{:ok, :skipped, reason}` - Push was skipped (e.g., version matches)
    - `{:error, reason}` - Push failed (validation error, etc.)

  ## Examples

      alias PhoenixGenApi.Structs.PushConfig

      push_config = %PushConfig{
        service: "my_service",
        nodes: [:"node1@host"],
        config_version: "1.0.0",
        fun_configs: [%FunConfig{...}]
      }

      {:ok, :accepted} = PhoenixGenApi.push_config(push_config)
      {:ok, :skipped, :version_matches} = PhoenixGenApi.push_config(push_config)
      {:ok, :accepted} = PhoenixGenApi.push_config(push_config, force: true)
  """
  @spec push_config(PhoenixGenApi.Structs.PushConfig.t() | map(), keyword()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push_config(push_config, opts \\ []) do
    PhoenixGenApi.ConfigReceiver.push(push_config, opts)
  end

  @doc """
  Verifies that the server has the given service and config version.

  Useful for checking whether a push is necessary before sending the full
  configuration. Remote nodes should use `ConfigPusher.verify/3` instead.

  ## Parameters

    - `service` - The service name (string or atom)
    - `config_version` - The config version string to verify

  ## Returns

    - `{:ok, :matched}` - Version matches what is stored
    - `{:ok, :mismatch, stored_version}` - Version differs from what is stored
    - `{:error, :not_found}` - Service is not known

  ## Examples

      {:ok, :matched} = PhoenixGenApi.verify_config("my_service", "1.0.0")
      {:ok, :mismatch, "0.9.0"} = PhoenixGenApi.verify_config("my_service", "1.0.0")
      {:error, :not_found} = PhoenixGenApi.verify_config("unknown_service", "1.0.0")
  """
  @spec verify_config(String.t() | atom(), String.t()) ::
          {:ok, :matched} | {:ok, :mismatch, String.t()} | {:error, :not_found}
  def verify_config(service, config_version) do
    PhoenixGenApi.ConfigReceiver.verify(service, config_version)
  end

  @doc """
  [Shell Helper] Quick view of pushed services status.

  Shows all services that have been registered via push, along with their
  config versions and auto-pull registration status.

  ## Usage in IEx

      iex> PhoenixGenApi.pushed_services_status()
  """
  def pushed_services_status() do
    IO.puts("\n=== Pushed Services Status ===\n")

    pushed_services = PhoenixGenApi.ConfigReceiver.get_all_pushed_services()

    if map_size(pushed_services) == 0 do
      IO.puts("No pushed services registered.")
    else
      Enum.each(pushed_services, fn {service, version} ->
        push_config = PhoenixGenApi.ConfigReceiver.get_pushed_config(service)
        auto_pull = if push_config.module && push_config.function, do: "Yes", else: "No"
        IO.puts("  #{inspect(service)}: version=#{inspect(version)}, auto_pull=#{auto_pull}")
      end)
    end

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Quick view of failed FunConfig entries.

  Shows configs that failed validation during pull or push, with their
  service, request_type, version, source, node, and reason.

  ## Usage in IEx

      iex> PhoenixGenApi.failed_configs()
      iex> PhoenixGenApi.failed_configs(source: :pull)
      iex> PhoenixGenApi.failed_configs(source: :push, limit: 20)
  """
  def failed_configs(opts \\ []) do
    PhoenixGenApi.ConfigFailed.list(opts)
  end

  @doc """
  [Shell Helper] Print a formatted table of failed FunConfig entries to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.failed_configs_print()
      iex> PhoenixGenApi.failed_configs_print(source: :pull, limit: 10)
  """
  def failed_configs_print(opts \\ []) do
    entries = PhoenixGenApi.ConfigFailed.list(opts)
    source_filter = Keyword.get(opts, :source)
    limit = Keyword.get(opts, :limit, 100)

    IO.puts("\n=== Failed FunConfig Entries ===")

    if source_filter do
      IO.puts("Source: #{source_filter}")
    end

    IO.puts("Showing: #{length(entries)} entries (limit: #{limit})")

    if entries == [] do
      IO.puts("  (no failed entries)")
    else
      header =
        String.pad_trailing("ID", 8) <>
          String.pad_trailing("Service", 20) <>
          String.pad_trailing("Request Type", 22) <>
          String.pad_trailing("Version", 10) <> String.pad_trailing("Source", 8) <> "Reason"

      IO.puts("\n" <> header)
      IO.puts(String.duplicate("-", 90))

      Enum.each(entries, fn entry ->
        id_str = String.pad_trailing("#{entry.id}", 8)
        svc_str = String.pad_trailing(inspect(entry.service), 20)
        req_str = String.pad_trailing(inspect(entry.request_type), 22)
        ver_str = String.pad_trailing(inspect(entry.version), 10)
        src_str = String.pad_trailing(inspect(entry.source), 8)
        reason_str = Enum.join(entry.reason, "; ")
        IO.puts(id_str <> svc_str <> req_str <> ver_str <> src_str <> reason_str)
      end)
    end

    IO.puts("")
    :ok
  end

  @doc """
  [Shell Helper] Print a summary of failed FunConfig entries to the console.

  ## Usage in IEx

      iex> PhoenixGenApi.failed_configs_summary()
  """
  def failed_configs_summary() do
    summary = PhoenixGenApi.ConfigFailed.summary()

    IO.puts("\n=== Failed Configs Summary ===")
    IO.puts("Total:  #{summary.total}")
    IO.puts("Pull:   #{summary.pull}")
    IO.puts("Push:   #{summary.push}")

    if summary.by_service != %{} do
      IO.puts("\n--- By Service ---")

      Enum.each(summary.by_service, fn {service, entries} ->
        IO.puts("  #{inspect(service)}: #{length(entries)} failed")
      end)
    end

    if summary.newest do
      IO.puts("\n--- Newest ---")
      n = summary.newest

      IO.puts(
        "  ##{n.id} #{inspect(n.service)}/#{inspect(n.request_type)} [#{n.source}] #{Enum.join(n.reason, "; ")}"
      )
    end

    IO.puts("")
    :ok
  end

  @doc """
  Cleans up expired failed config entries (older than 24h).
  Returns the number of entries removed.
  """
  @spec cleanup_failed_configs() :: non_neg_integer()
  def cleanup_failed_configs do
    PhoenixGenApi.ConfigFailed.cleanup()
  end

  @doc """
  Clears all failed config entries regardless of expiry.
  """
  @spec clear_failed_configs() :: :ok
  def clear_failed_configs do
    PhoenixGenApi.ConfigFailed.clear()
  end

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use PhoenixGenApi.ImplHelper,
        encoder: Module.concat(Application.compile_env(:phoenix, :json_library, JSON), Encoder),
        impl: [
          PhoenixGenApi.Structs.Response
        ]

      @phoenix_gen_api_override_user_id Keyword.get(opts, :override_user_id, true)
      @phoenix_gen_api_require_verified_user_id Keyword.get(opts, :require_verified_user_id, true)
      @phoenix_gen_api_event Keyword.get(opts, :event, "phoenix_gen_api")

      require Logger

      @impl true
      @doc false
      def handle_in(@phoenix_gen_api_event, payload, socket) do
        Logger.debug(fn ->
          "[PhoenixGenApi] incoming request, module: #{__MODULE__}, payload: #{inspect(payload)}"
        end)

        # Only override user_id from socket assigns if it's a valid non-empty string.
        # Previously, nil user_ids from socket.assigns would be set in the payload,
        # which could bypass :any_authenticated permission checks.
        payload =
          if @phoenix_gen_api_override_user_id do
            case Map.get(socket.assigns, :user_id) do
              user_id when is_binary(user_id) and byte_size(user_id) > 0 ->
                Map.put(payload, "user_id", user_id)

              _ ->
                payload
            end
          else
            payload
          end

        # When require_verified_user_id is true, reject requests immediately
        # if socket.assigns does not contain a verified non-empty user_id.
        # This prevents unauthenticated requests from reaching permission checks
        # or function execution. Set to false for public endpoints.
        {reply_result, push_response} =
          if @phoenix_gen_api_require_verified_user_id do
            case Map.get(socket.assigns, :user_id) do
              user_id when is_binary(user_id) and byte_size(user_id) > 0 ->
                do_handle_request(payload, socket)

              _ ->
                request_id = Map.get(payload, "request_id", "unknown")

                Logger.warning(
                  "[PhoenixGenApi] rejected unauthenticated request, module: #{__MODULE__}, request_id: #{inspect(request_id)}"
                )

                error_response =
                  PhoenixGenApi.Structs.Response.error_response(
                    request_id,
                    "Authentication required"
                  )

                {{:error, "Authentication required"}, error_response}
            end
          else
            do_handle_request(payload, socket)
          end

        if push_response do
          push(socket, @phoenix_gen_api_event, push_response)
        end

        {:reply, reply_result, socket}
      end

      defp do_handle_request(payload, _socket) do
        try do
          request = PhoenixGenApi.Structs.Request.decode!(payload)

          case PhoenixGenApi.Executor.execute!(request) do
            %PhoenixGenApi.Structs.Response{} = result ->
              {{:ok, request.request_type}, result}

            {:ok, :no_response} ->
              {{:ok, request.request_type}, nil}
          end
        rescue
          e in PhoenixGenApi.Errors.DecodeError ->
            request_id = Map.get(payload, "request_id", "unknown")

            Logger.warning(
              "[PhoenixGenApi] decode error, module: #{__MODULE__}, request_id: #{inspect(request_id)}, code: #{inspect(e.code)}, error: #{e.message}"
            )

            error_response =
              PhoenixGenApi.Structs.Response.error_response(
                request_id,
                "Invalid request: #{e.message}"
              )

            {{:error, e.message}, error_response}

          e ->
            request_id = Map.get(payload, "request_id", "unknown")

            Logger.error(
              "[PhoenixGenApi] request processing failed, module: #{__MODULE__}, request_id: #{inspect(request_id)}, error: #{Exception.message(e)}"
            )

            error_response =
              PhoenixGenApi.Structs.Response.error_response(
                request_id,
                "Request processing failed"
              )

            {{:error, Exception.message(e)}, error_response}
        end
      end

      @doc false
      def handle_info({:stream_started, request_id, pid}, socket) do
        Process.put({:phoenix_gen_api, :stream_call_pid, request_id}, pid)
        {:noreply, socket}
      end

      @doc false
      @impl true
      def handle_info({:push, result}, socket) do
        Logger.debug(fn ->
          "[PhoenixGenApi] push result, module: #{__MODULE__}, result: #{inspect(result)}"
        end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:stream_response, result}, socket) do
        Logger.debug(fn ->
          "[PhoenixGenApi] stream response, module: #{__MODULE__}, result: #{inspect(result)}"
        end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:async_call, result}, socket) do
        Logger.debug(fn ->
          "[PhoenixGenApi] async call result, module: #{__MODULE__}, result: #{inspect(result)}"
        end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:relay_message, result}, socket) do
        Logger.debug(fn ->
          "[PhoenixGenApi] relay message, module: #{__MODULE__}, result: #{inspect(result)}"
        end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end
    end
  end
end
