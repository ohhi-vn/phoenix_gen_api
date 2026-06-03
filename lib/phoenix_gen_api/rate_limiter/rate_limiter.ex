defmodule PhoenixGenApi.RateLimiter do
  @moduledoc """
  Provides rate limiting functionality for API requests.

  This module implements a sliding window rate limiter using ETS for high-performance
  tracking. It supports both global rate limiting (across all APIs) and per-API
  rate limiting with configurable limits.

  ## Architecture

  The rate limiter uses a sliding window algorithm with ETS tables for storage:
  - **Global Table**: Tracks request counts per key across all APIs
  - **API Table**: Tracks request counts per key per API

  ## Rate Limiting Strategies

  ### Global Rate Limiting
  Applies a single rate limit across all API requests for a given key.
  Useful for preventing overall system abuse.

  ### Per-API Rate Limiting
  Applies specific rate limits to individual API endpoints.
  Useful for protecting expensive or sensitive operations.

  ## Configuration

  Configure rate limits in your `config.exs`:

      config :phoenix_gen_api, :rate_limiter,
        enabled: true,
        # Multi-instance configuration for better concurrency
        # Number of RateLimiter instances (default: number of online schedulers)
        instance_count: :auto,  # :auto or positive integer
        # Routing strategy for distributing requests across instances
        # - :hash - Consistent routing based on request_id (default, ensures same request goes to same instance)
        # - :random - Random distribution across instances
        routing_strategy: :hash,
        global_limits: [
          # Default: 2000 requests per minute per user
          %{key: :user_id, max_requests: 2000, window_ms: 60_000},
          # Device-level: 10000 requests per minute per device
          %{key: :device_id, max_requests: 10000, window_ms: 60_000}
        ],
        api_limits: [
          # Expensive operation: 10 requests per minute per user
          %{
            service: "data_service",
            request_type: "export_data",
            key: :user_id,
            max_requests: 10,
            window_ms: 60_000
          },
          # Public endpoint: 100 requests per minute per IP
          %{
            service: "public_service",
            request_type: "search",
            key: :ip_address,
            max_requests: 100,
            window_ms: 60_000
          }
        ]

  ## Usage

  ### Basic Usage

      # Check rate limit before executing a request
      case RateLimiter.check_rate_limit(request) do
        :ok ->
          # Execute the request
          Executor.execute!(request)

        {:error, :rate_limited, details} ->
          # Return rate limit error to client
          Response.error_response(request.request_id, "Rate limit exceeded")
      end

  ### Manual Rate Limiting

      # Check global rate limit
      RateLimiter.check_rate_limit("user_123", :global, :user_id)

      # Check API-specific rate limit
      RateLimiter.check_rate_limit("user_123", {"my_service", "my_api"}, :user_id)

  ## Rate Limit Keys

  The rate limiter supports various key types:
  - `:user_id` - Rate limit by user
  - `:device_id` - Rate limit by device
  - `:ip_address` - Rate limit by IP address
  - Custom keys - Any string value

  ## Sliding Window Algorithm

  The rate limiter uses a sliding window algorithm that:
  1. Tracks individual request timestamps
  2. Removes expired entries outside the window
  3. Counts remaining entries to determine current usage
  4. Provides accurate rate limiting without fixed window boundaries

  ## Performance

  - ETS tables provide O(1) average-case lookups
  - Cleanup runs periodically to remove expired entries
  - Memory usage is bounded by max_requests × number of keys
  - Read/write concurrency is enabled for high-throughput scenarios

  ## Fault Tolerance

  - Rate limiter failures do not block request execution (fail-open by default)
  - ETS tables are automatically cleaned up on process termination
  - Configuration changes are applied without restart
  """

  use GenServer, restart: :permanent

  require Logger

  @supervisor :rate_limiter_supervisor
  @instance_prefix :rate_limiter_instance_

  @default_cleanup_interval 60_000

  @doc """
  Attaches a telemetry handler to rate limiter events.

  ## Events

  - `[:phoenix_gen_api, :rate_limiter, :check]` - Emitted on every rate limit check
  - `[:phoenix_gen_api, :rate_limiter, :exceeded]` - Emitted when a rate limit is exceeded
  - `[:phoenix_gen_api, :rate_limiter, :reset]` - Emitted when rate limits are reset
  - `[:phoenix_gen_api, :rate_limiter, :cleanup]` - Emitted during periodic cleanup

  ## Examples

      # Attach a handler
      :telemetry.attach(
        "my-rate-limiter-handler",
        [:phoenix_gen_api, :rate_limiter, :check],
        fn event, measurements, metadata, config ->
        ...
        end,
        %{}
      )

      # Or use the helper function
      PhoenixGenApi.RateLimiter.attach_telemetry("my-handler", &my_handler/4)
  """
  def attach_telemetry(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    :telemetry.attach(
      "#{handler_id}-check",
      [:phoenix_gen_api, :rate_limiter, :check],
      function,
      config
    )

    :telemetry.attach(
      "#{handler_id}-exceeded",
      [:phoenix_gen_api, :rate_limiter, :exceeded],
      function,
      config
    )

    :telemetry.attach(
      "#{handler_id}-reset",
      [:phoenix_gen_api, :rate_limiter, :reset],
      function,
      config
    )

    :telemetry.attach(
      "#{handler_id}-cleanup",
      [:phoenix_gen_api, :rate_limiter, :cleanup],
      function,
      config
    )

    :ok
  end

  @doc """
  Detaches a telemetry handler by ID.
  """
  def detach_telemetry(handler_id) when is_binary(handler_id) do
    :telemetry.detach("#{handler_id}-check")
    :telemetry.detach("#{handler_id}-exceeded")
    :telemetry.detach("#{handler_id}-reset")
    :telemetry.detach("#{handler_id}-cleanup")
    :ok
  end

  @type rate_limit_key :: :user_id | :device_id | :ip_address | String.t()
  @type api_identifier :: {String.t() | atom(), String.t()}
  @type check_result :: :ok | {:error, :rate_limited, rate_limit_details()}

  @type rate_limit_details :: %{
          key: String.t(),
          max_requests: non_neg_integer(),
          current_requests: non_neg_integer(),
          window_ms: non_neg_integer(),
          retry_after_ms: non_neg_integer(),
          scope: :global | api_identifier()
        }

  @doc """
  Starts the RateLimiter and its instances under a supervisor.
  """
  def start_link(opts \\ []) do
    instance_count = get_instance_count()
    routing_strategy = get_routing_strategy()

    # Start the supervisor that will manage all instances
    children =
      for i <- 0..(instance_count - 1) do
        name = instance_name(i)

        %{
          id: name,
          start:
            {GenServer, :start_link, [__MODULE__, [{:instance_index, i} | opts], [name: name]]},
          restart: :permanent
        }
      end

    supervisor_opts = [
      strategy: :one_for_one,
      name: @supervisor
    ]

    case Supervisor.start_link(children, supervisor_opts) do
      {:ok, sup_pid} ->
        Logger.info(
          "[RateLimiter] started, instances: #{instance_count}, routing: #{routing_strategy}"
        )

        {:ok, sup_pid}

      error ->
        error
    end
  end

  @doc """
  Returns the number of active rate limiter instances.
  """
  def instance_count() do
    if Process.whereis(instance_name(0)) do
      get_instance_count()
    else
      0
    end
  end

  @doc """
  Returns the routing strategy being used.
  """
  def routing_strategy() do
    get_routing_strategy()
  end

  # Instance name helper
  defp instance_name(index) when is_integer(index) do
    String.to_atom("#{@instance_prefix}#{index}")
  end

  # Get instance count from config or default to online schedulers
  defp get_instance_count() do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:instance_count] do
      :auto -> :erlang.system_info(:schedulers_online)
      count when is_integer(count) and count > 0 -> count
      _ -> :erlang.system_info(:schedulers_online)
    end
  end

  # Get routing strategy from config
  defp get_routing_strategy() do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:routing_strategy] do
      :random -> :random
      :hash -> :hash
      _ -> :hash
    end
  end

  # Select instance based on routing strategy
  defp select_instance(request) do
    instance_count = get_instance_count()
    strategy = get_routing_strategy()

    # Use user_id as the primary routing key (most common rate limit key)
    # Fall back to request_id if user_id is not present
    routing_value = Map.get(request, :user_id) || Map.get(request, :request_id) || ""

    index =
      case strategy do
        :random ->
          :rand.uniform(instance_count) - 1

        :hash ->
          :erlang.phash2(routing_value, instance_count)
      end

    instance_name(index)
  end

  defp select_instance_for_direct(key_value, scope) do
    instance_count = get_instance_count()
    strategy = get_routing_strategy()

    index =
      case strategy do
        :random ->
          :rand.uniform(instance_count) - 1

        :hash ->
          # Hash based on key_value and scope for consistent routing
          hash_input = "#{inspect(scope)}:#{key_value}"
          :erlang.phash2(hash_input, instance_count)
      end

    instance_name(index)
  end

  @doc """
  Checks if a request is within rate limits.

  This function checks both global and per-API rate limits configured for the
  request. If any limit is exceeded, it returns an error with details.

  ## Parameters

    - `request` - The `Request` struct to check

  ## Returns

    - `:ok` - Request is within all rate limits
    - `{:error, :rate_limited, details}` - Request exceeds a rate limit

  ## Examples

      request = %Request{
        user_id: "user_123",
        device_id: "device_456",
        service: "my_service",
        request_type: "my_api"
      }

      case RateLimiter.check_rate_limit(request) do
        :ok ->
          # Proceed with request execution

        {:error, :rate_limited, details} ->
          # Return rate limit error
          ...
      end
  """
  def check_rate_limit(request) do
    if enabled?() do
      start_time = System.monotonic_time(:microsecond)
      instance = select_instance(request)
      result = GenServer.call(instance, {:check_rate_limit, request})
      duration = System.monotonic_time(:microsecond) - start_time

      :telemetry.execute(
        [:phoenix_gen_api, :rate_limiter, :check],
        %{duration_us: duration},
        %{
          request_id: request.request_id,
          user_id: request.user_id,
          instance: instance,
          service: request.service,
          request_type: request.request_type,
          result: result
        }
      )

      if match?({:error, :rate_limited, _}, result) do
        {:error, :rate_limited, details} = result

        :telemetry.execute(
          [:phoenix_gen_api, :rate_limiter, :exceeded],
          %{retry_after_ms: details.retry_after_ms},
          %{
            key: details.key,
            scope: details.scope,
            max_requests: details.max_requests,
            current_requests: details.current_requests,
            request_id: request.request_id,
            user_id: request.user_id
          }
        )
      end

      result
    else
      :ok
    end
  rescue
    e ->
      if fail_open?() do
        Logger.error(
          "[RateLimiter] check_rate_limit failed, allowing request (fail-open): #{Exception.message(e)}"
        )

        :ok
      else
        {:error, :rate_limiter_error, %{message: Exception.message(e)}}
      end
  end

  @doc """
  Checks rate limit for a specific key and scope.

  ## Parameters

    - `key_value` - The value to rate limit against (e.g., user ID)
    - `scope` - Either `:global` or `{service, request_type}` tuple
    - `rate_limit_key` - The type of key (`:user_id`, `:device_id`, etc.)

  ## Returns

    - `:ok` - Within rate limit
    - `{:error, :rate_limited, details}` - Exceeded rate limit

  ## Examples

      # Check global rate limit for a user
      RateLimiter.check_rate_limit("user_123", :global, :user_id)

      # Check API-specific rate limit
      RateLimiter.check_rate_limit("user_123", {"service", "api"}, :user_id)
  """
  @spec check_rate_limit(String.t(), :global | api_identifier(), rate_limit_key()) ::
          :ok | {:error, :rate_limited, rate_limit_details()}
  def check_rate_limit(key_value, scope, rate_limit_key) do
    if enabled?() do
      instance = select_instance_for_direct(key_value, scope)
      GenServer.call(instance, {:check_rate_limit_direct, key_value, scope, rate_limit_key})
    else
      :ok
    end
  end

  @doc """
  Resets rate limit counters for a specific key.

  ## Parameters

    - `key_value` - The key value to reset (e.g., user ID)
    - `scope` - Either `:global` or `{service, request_type}` tuple
    - `rate_limit_key` - The type of key

  ## Returns

    - `:ok` - Counters were reset

  ## Examples

      # Reset all rate limits for a user
      RateLimiter.reset_rate_limit("user_123", :global, :user_id)
  """
  @spec reset_rate_limit(String.t(), :global | api_identifier(), rate_limit_key()) :: :ok
  def reset_rate_limit(key_value, scope, rate_limit_key) do
    instance = select_instance_for_direct(key_value, scope)
    result = GenServer.call(instance, {:reset_rate_limit, key_value, scope, rate_limit_key})

    :telemetry.execute(
      [:phoenix_gen_api, :rate_limiter, :reset],
      %{},
      %{
        key: key_value,
        scope: scope,
        rate_limit_key: rate_limit_key
      }
    )

    result
  end

  @doc """
  Gets current rate limit status for a key.

  ## Returns

    A map with current usage information for all applicable rate limits.
  """
  @spec get_rate_limit_status(String.t(), :global | api_identifier(), rate_limit_key()) :: map()
  def get_rate_limit_status(key_value, scope, rate_limit_key) do
    instance = select_instance_for_direct(key_value, scope)
    GenServer.call(instance, {:get_rate_limit_status, key_value, scope, rate_limit_key})
  end

  @doc """
  Gets all configured rate limits.
  """
  @spec get_configured_limits() :: %{global: list(), api: list()}
  def get_configured_limits() do
    # This is a global config, can query any instance
    instance = instance_name(0)
    GenServer.call(instance, :get_configured_limits)
  end

  @doc """
  Gets the current global rate limits (may differ from config.exs if changed at runtime).

  ## Returns

    A list of global rate limit maps.

  ## Examples

      PhoenixGenApi.RateLimiter.get_global_limits()
      # => [%{key: :user_id, max_requests: 2000, window_ms: 60_000}]
  """
  @spec get_global_limits() :: [map()]
  def get_global_limits() do
    # This is a global config, can query any instance
    instance = instance_name(0)
    GenServer.call(instance, :get_global_limits)
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

      PhoenixGenApi.RateLimiter.set_global_limits([
        %{key: :user_id, max_requests: 2000, window_ms: 60_000},
        %{key: :device_id, max_requests: 10000, window_ms: 60_000}
      ])
  """
  @spec set_global_limits([map()]) :: :ok
  def set_global_limits(limits) when is_list(limits) do
    broadcast_to_all_instances({:set_global_limits, limits})
  end

  defp broadcast_to_all_instances(message) do
    instance_count = get_instance_count()

    for i <- 0..(instance_count - 1) do
      instance = instance_name(i)
      GenServer.call(instance, message)
    end

    :ok
  end

  @doc """
  Adds a single global rate limit at runtime.

  If a limit with the same `:key` already exists, it will be replaced.

  ## Parameters

    - `limit` - A map with `:key`, `:max_requests`, and `:window_ms`

  ## Returns

    - `:ok` - Limit was added

  ## Examples

      PhoenixGenApi.RateLimiter.add_global_limit(%{
        key: :ip_address,
        max_requests: 100,
        window_ms: 60_000
      })
  """
  @spec add_global_limit(map()) :: :ok
  def add_global_limit(limit) when is_map(limit) do
    broadcast_to_all_instances({:add_global_limit, limit})
  end

  @doc """
  Removes a global rate limit by key at runtime.

  ## Parameters

    - `key` - The rate limit key to remove (`:user_id`, `:device_id`, etc.)

  ## Returns

    - `:ok` - Limit was removed (or didn't exist)

  ## Examples

      PhoenixGenApi.RateLimiter.remove_global_limit(:ip_address)
  """
  @spec remove_global_limit(atom() | String.t()) :: :ok
  def remove_global_limit(key) do
    broadcast_to_all_instances({:remove_global_limit, key})
  end

  @doc """
  Updates rate limit configuration at runtime.

  ## Parameters

    - `config` - A map with `:global_limits` and/or `:api_limits` keys

  ## Returns

    - `:ok` - Configuration was updated

  ## Examples

      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 2000, window_ms: 60_000}
        ]
      })
  """
  @spec update_config(map()) :: :ok | {:error, :admin_action_denied}
  def update_config(config) when is_map(config) do
    with true <- PhoenixGenApi.Security.admin_action_allowed?(:update_rate_limit_config),
         true <-
           !Map.has_key?(config, :detail_error) or
             PhoenixGenApi.Security.admin_action_allowed?(:change_detail_error) do
      broadcast_to_all_instances({:update_config, config})
    else
      false -> {:error, :admin_action_denied}
    end
  end

  @doc """
  Clears all rate limit data from ETS tables.

  Useful for testing or resetting rate limit counters.
  """
  @spec clear() :: :ok
  def clear() do
    broadcast_to_all_instances(:clear)
  end

  ### Callbacks

  @impl true
  def init(opts) do
    instance_index = Keyword.get(opts, :instance_index, 0)

    # Create ETS tables for rate limiting (only if they don't exist)
    # Multiple instances will share these tables
    case :ets.whereis(:rate_limiter_global) do
      :undefined ->
        :ets.new(:rate_limiter_global, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    case :ets.whereis(:rate_limiter_api) do
      :undefined ->
        :ets.new(:rate_limiter_api, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    state = %{
      instance_index: instance_index,
      global_limits: load_global_limits(),
      api_limits: load_api_limits(),
      cleanup_interval: cleanup_interval()
    }

    Logger.info(
      "[RateLimiter] instance #{instance_index} initialized, global_limits: #{length(state.global_limits)}, api_limits: #{length(state.api_limits)}, cleanup_interval: #{state.cleanup_interval}ms"
    )

    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:check_rate_limit, request}, _from, state) do
    result = check_request_limits(request, state)
    {:reply, result, state}
  end

  def handle_call({:check_rate_limit_direct, key_value, scope, rate_limit_key}, _from, state) do
    result = check_direct_limit(key_value, scope, rate_limit_key, state)
    {:reply, result, state}
  end

  def handle_call({:reset_rate_limit, key_value, scope, rate_limit_key}, _from, state) do
    reset_limit(key_value, scope, rate_limit_key)
    {:reply, :ok, state}
  end

  def handle_call({:get_rate_limit_status, key_value, scope, rate_limit_key}, _from, state) do
    status = get_limit_status(key_value, scope, rate_limit_key, state)
    {:reply, status, state}
  end

  def handle_call(:get_configured_limits, _from, state) do
    {:reply, %{global: state.global_limits, api: state.api_limits}, state}
  end

  def handle_call(:get_global_limits, _from, state) do
    {:reply, state.global_limits, state}
  end

  def handle_call({:set_global_limits, limits}, _from, state) do
    Logger.info("[RateLimiter] global limits replaced: #{inspect(limits)}")
    {:reply, :ok, %{state | global_limits: limits}}
  end

  def handle_call({:add_global_limit, limit}, _from, state) do
    key = Map.get(limit, :key)

    new_limits =
      state.global_limits
      |> Enum.reject(fn l -> Map.get(l, :key) == key end)
      |> Enum.concat([limit])

    Logger.info("[RateLimiter] global limit added/updated: #{inspect(limit)}")
    {:reply, :ok, %{state | global_limits: new_limits}}
  end

  def handle_call({:remove_global_limit, key}, _from, state) do
    new_limits = Enum.reject(state.global_limits, fn l -> Map.get(l, :key) == key end)

    Logger.info(
      "[RateLimiter] global limit removed, key: #{inspect(key)}, remaining: #{length(new_limits)}"
    )

    {:reply, :ok, %{state | global_limits: new_limits}}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(:rate_limiter_global)
    :ets.delete_all_objects(:rate_limiter_api)
    {:reply, :ok, state}
  end

  def handle_call({:update_config, config}, _from, state) do
    new_state =
      state
      |> maybe_update_global_limits(config)
      |> maybe_update_api_limits(config)

    Logger.info("[RateLimiter] configuration updated")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    start_time = System.monotonic_time(:microsecond)
    cleaned_count = perform_cleanup(state.instance_index)
    duration = System.monotonic_time(:microsecond) - start_time

    :telemetry.execute(
      [:phoenix_gen_api, :rate_limiter, :cleanup],
      %{duration_us: duration, cleaned_entries: cleaned_count},
      %{
        global_limits_count: length(state.global_limits),
        api_limits_count: length(state.api_limits)
      }
    )

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Don't delete ETS tables - other instances might still be using them
    # Tables will be cleaned up when the VM terminates
    :ok
  end

  ### Private Functions

  defp check_request_limits(request, state) do
    # Check global limits
    case check_global_limits(request, state.global_limits) do
      {:error, _reason, _details} = error -> error
      :ok -> check_api_limits(request, state.api_limits)
    end
  end

  defp check_global_limits(request, global_limits) do
    Enum.reduce_while(global_limits, :ok, fn limit, _acc ->
      key_value = get_key_value(request, limit.key)

      if is_binary(key_value) and byte_size(key_value) > 0 do
        case check_and_record(:rate_limiter_global, key_value, limit) do
          :ok -> {:cont, :ok}
          {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp check_api_limits(request, api_limits) do
    Enum.reduce_while(api_limits, :ok, fn limit, _acc ->
      if limit.service == request.service and limit.request_type == request.request_type do
        key_value = get_key_value(request, limit.key)

        if is_binary(key_value) and byte_size(key_value) > 0 do
          scope = {limit.service, limit.request_type}

          case check_and_record(:rate_limiter_api, build_api_key(key_value, scope), limit) do
            :ok -> {:cont, :ok}
            {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
          end
        else
          {:cont, :ok}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp check_direct_limit(key_value, scope, rate_limit_key, state) do
    limits =
      case scope do
        :global ->
          state.global_limits

        {service, request_type} ->
          Enum.filter(state.api_limits, fn limit ->
            limit.service == service and limit.request_type == request_type and
              limit.key == rate_limit_key
          end)
      end

    if limits == [] do
      :ok
    else
      Enum.reduce_while(limits, :ok, fn limit, _acc ->
        ets_key =
          case scope do
            :global -> key_value
            _ -> build_api_key(key_value, scope)
          end

        case check_and_record(ets_table_for_scope(scope), ets_key, limit) do
          :ok -> {:cont, :ok}
          {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
        end
      end)
    end
  end

  defp check_and_record(table, key, limit) do
    now = System.monotonic_time(:millisecond)
    window_start = now - limit.window_ms

    case :ets.lookup(table, key) do
      [{^key, timestamps}] ->
        # Filter out expired timestamps
        valid_timestamps = Enum.reject(timestamps, fn ts -> ts <= window_start end)
        current_count = length(valid_timestamps)

        if current_count >= limit.max_requests do
          # Rate limit exceeded
          oldest_valid = List.last(valid_timestamps)
          retry_after_ms = oldest_valid + limit.window_ms - now

          details = %{
            key: key,
            max_requests: limit.max_requests,
            current_requests: current_count,
            window_ms: limit.window_ms,
            retry_after_ms: max(retry_after_ms, 0),
            scope: get_scope_from_table(table, key)
          }

          Logger.warning(
            "[RateLimiter] rate limit exceeded, key: #{inspect(key)}, current: #{current_count}/#{limit.max_requests}, window: #{limit.window_ms}ms, retry_after: #{retry_after_ms}ms"
          )

          {:error, :rate_limited, details}
        else
          # Within limit, add new timestamp and keep list bounded
          new_timestamps = Enum.take([now | valid_timestamps], limit.max_requests)
          :ets.insert(table, {key, new_timestamps})
          :ok
        end

      [] ->
        # No existing entry, create new one
        :ets.insert(table, {key, [now]})
        :ok
    end
  end

  defp reset_limit(key_value, scope, _rate_limit_key) do
    table = ets_table_for_scope(scope)

    ets_key =
      case scope do
        :global -> key_value
        _ -> build_api_key(key_value, scope)
      end

    :ets.delete(table, ets_key)

    Logger.info(
      "[RateLimiter] rate limit reset, key: #{inspect(key_value)}, scope: #{inspect(scope)}"
    )
  end

  defp get_limit_status(key_value, scope, _rate_limit_key, state) do
    table = ets_table_for_scope(scope)

    ets_key =
      case scope do
        :global -> key_value
        _ -> build_api_key(key_value, scope)
      end

    limits =
      case scope do
        :global ->
          state.global_limits

        {service, request_type} ->
          Enum.filter(state.api_limits, fn limit ->
            limit.service == service and limit.request_type == request_type
          end)
      end

    now = System.monotonic_time(:millisecond)

    existing_timestamps =
      case :ets.lookup(table, ets_key) do
        [{^ets_key, timestamps}] -> timestamps
        [] -> []
      end

    # Pre-compute valid count once if all limits share the same window
    # Otherwise compute per-limit
    Enum.map(limits, fn limit ->
      window_start = now - limit.window_ms
      valid_count = count_valid_timestamps(existing_timestamps, window_start)

      %{
        key: ets_key,
        max_requests: limit.max_requests,
        current_requests: valid_count,
        window_ms: limit.window_ms,
        remaining: max(limit.max_requests - valid_count, 0),
        scope: scope
      }
    end)
  end

  # Counts timestamps within the sliding window.
  # Although this scans all timestamps, the list is bounded by `max_requests`
  # (we cap it via `Enum.take` in `check_and_record`), so the iteration is
  # always O(max_requests) — typically a small constant. An early-exit variant
  # would only save work when the limit is exceeded, which is the uncommon path.
  defp count_valid_timestamps(timestamps, window_start) do
    Enum.count(timestamps, fn ts -> ts > window_start end)
  end

  defp get_key_value(request, key) do
    case key do
      :user_id ->
        val = request.user_id
        if is_binary(val), do: val, else: nil

      :device_id ->
        val = request.device_id
        if is_binary(val), do: val, else: nil

      :ip_address ->
        Map.get(request, :ip_address)

      custom_key when is_binary(custom_key) ->
        Map.get(request.args, custom_key)

      _ ->
        nil
    end
  end

  defp build_api_key(key_value, {service, request_type}) do
    "#{service}:#{request_type}:#{key_value}"
  end

  defp ets_table_for_scope(:global), do: :rate_limiter_global
  defp ets_table_for_scope({_service, _request_type}), do: :rate_limiter_api

  defp get_scope_from_table(:rate_limiter_global, _key), do: :global

  defp get_scope_from_table(:rate_limiter_api, key) do
    case String.split(key, ":", parts: 3) do
      [service, request_type, _key_value] -> {service, request_type}
      _ -> :global
    end
  end

  # Sharded cleanup: each instance only cleans keys that hash to its shard.
  # This avoids N instances each doing a full table scan, reducing total work
  # from O(N * keys) to O(keys) across the cluster.
  defp perform_cleanup(instance_index) do
    now = System.monotonic_time(:millisecond)
    total_instances = get_instance_count()

    # Clean global table (sharded)
    global_cleaned =
      cleanup_table_sharded(:rate_limiter_global, now, instance_index, total_instances)

    # Clean API table (sharded)
    api_cleaned = cleanup_table_sharded(:rate_limiter_api, now, instance_index, total_instances)

    Logger.debug(
      "[RateLimiter] cleanup completed (shard #{instance_index}/#{total_instances}), removed: #{global_cleaned + api_cleaned} entries (global: #{global_cleaned}, api: #{api_cleaned})"
    )

    global_cleaned + api_cleaned
  end

  # Sharded cleanup: only processes keys where phash2(key) rem total_instances == shard_index.
  # This distributes cleanup work evenly across instances without coordination.
  defp cleanup_table_sharded(table, now, shard_index, total_instances) do
    max_window = get_max_window_for_table(table)
    cutoff = now - max_window

    :ets.foldl(
      fn {key, timestamps}, acc ->
        # Only clean this key if it belongs to our shard
        if rem(:erlang.phash2(key), total_instances) == shard_index do
          # Use split_with for single-pass partitioning
          {valid_timestamps, expired} = Enum.split_with(timestamps, fn ts -> ts > cutoff end)

          if expired == [] do
            # No expired entries, skip update
            acc
          else
            if valid_timestamps == [] do
              :ets.delete(table, key)
            else
              :ets.insert(table, {key, valid_timestamps})
            end

            acc + length(expired)
          end
        else
          acc
        end
      end,
      0,
      table
    )
  end

  defp get_max_window_for_table(:rate_limiter_global) do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:global_limits] do
      nil -> @default_cleanup_interval
      limits -> Enum.map(limits, & &1.window_ms) |> Enum.max(fn -> @default_cleanup_interval end)
    end
  end

  defp get_max_window_for_table(:rate_limiter_api) do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:api_limits] do
      nil -> @default_cleanup_interval
      limits -> Enum.map(limits, & &1.window_ms) |> Enum.max(fn -> @default_cleanup_interval end)
    end
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :cleanup, @default_cleanup_interval)
  end

  defp load_global_limits() do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:global_limits] do
      nil -> []
      limits when is_list(limits) -> limits
      _ -> []
    end
  end

  defp load_api_limits() do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:api_limits] do
      nil -> []
      limits when is_list(limits) -> limits
      _ -> []
    end
  end

  defp enabled?() do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:enabled] != false
  end

  defp fail_open?() do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:fail_open] != false
  end

  defp cleanup_interval() do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:cleanup_interval] ||
      @default_cleanup_interval
  end

  defp maybe_update_global_limits(state, %{global_limits: limits}) when is_list(limits) do
    %{state | global_limits: limits}
  end

  defp maybe_update_global_limits(state, _), do: state

  defp maybe_update_api_limits(state, %{api_limits: limits}) when is_list(limits) do
    %{state | api_limits: limits}
  end

  defp maybe_update_api_limits(state, _), do: state
end
