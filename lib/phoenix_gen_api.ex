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
  - **Rate Limiting**: Global and per-API rate limiting with sliding window algorithm

  ## Architecture

  The library consists of several key components:

  - `PhoenixGenApi.Executor` - Core execution engine for processing requests
  - `PhoenixGenApi.ConfigDb` - Caches function configurations for fast lookup
  - `PhoenixGenApi.ConfigPuller` - Pulls and updates configurations from remote services
  - `PhoenixGenApi.NodeSelector` - Selects target nodes based on configured strategies
  - `PhoenixGenApi.Permission` - Handles permission checking for requests
  - `PhoenixGenApi.ArgumentHandler` - Validates and converts request arguments
  - `PhoenixGenApi.StreamCall` - Manages streaming function calls
  - `PhoenixGenApi.RateLimiter` - Rate limiting for global and per-API requests

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

  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.RateLimiter

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
        ) ::
          list(map())
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

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use PhoenixGenApi.ImplHelper,
        encoder: Module.concat(Application.compile_env(:phoenix, :json_library, JSON), Encoder),
        impl: [
          PhoenixGenApi.Structs.Response
        ]

      @phoenix_gen_api_override_user_id Keyword.get(opts, :override_user_id, true)
      @phoenix_gen_api_event Keyword.get(opts, :event, "phoenix_gen_api")

      require Logger

      @impl true
      @doc false
      def handle_in(@phoenix_gen_api_event, payload, socket) do
        Logger.debug(fn ->
          "PhoenixGenApi, #{__MODULE__}, request: #{inspect(payload)}"
        end)

        payload =
          if @phoenix_gen_api_override_user_id do
            Map.put(payload, "user_id", socket.assigns.user_id)
          else
            payload
          end

        request = PhoenixGenApi.Structs.Request.decode!(payload)

        case PhoenixGenApi.Executor.execute!(request) do
          %PhoenixGenApi.Structs.Response{} = result ->
            push(socket, @phoenix_gen_api_event, result)

          {:ok, :no_response} ->
            :ok
        end

        {:reply, {:ok, "#{request.request_type}"}, socket}
      end

      @doc false
      @impl true
      def handle_info({:push, result}, socket) do
        Logger.debug(fn -> "PhoenixGenApi, #{__MODULE__}, push result: #{inspect(result)}" end)
        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:stream_response, result}, socket) do
        Logger.debug(fn ->
          "PhoenixGenApi, #{__MODULE__}, stream response: #{inspect(result)}"
        end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:async_call, result}, socket) do
        Logger.debug(fn ->
          "PhoenixGenApi, #{__MODULE__}, async call result: #{inspect(result)}" end)

        push(socket, @phoenix_gen_api_event, result)
        {:noreply, socket}
      end
    end
  end
end
