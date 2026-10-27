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

  alias PhoenixGenApi.Helpers.Shared

  alias PhoenixGenApi.LogContext

  require Logger

  @supervisor :rate_limiter_supervisor
  @instance_prefix :rate_limiter_instance_
  @limits_key {__MODULE__, :effective_limits}

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

    if routing_strategy == :random do
      Logger.warning(
        LogContext.line(
          "RateLimiter",
          :random_routing_deprecated,
          ":random routing is deprecated and ignored; keys are routed by hash for correctness",
          node: node()
        )
      )
    end

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
          LogContext.line(
            "RateLimiter",
            :started,
            "started",
            instances: instance_count,
            routing: routing_strategy,
            node: node()
          )
        )

        {:ok, sup_pid}

      error ->
        error
    end
  end

  @doc """
  Returns the number of active rate limiter instances.
  """
  def instance_count do
    if Process.whereis(instance_name(0)) do
      get_instance_count()
    else
      0
    end
  end

  @doc """
  Returns the routing strategy being used.
  """
  def routing_strategy do
    get_routing_strategy()
  end

  # Instance name helper
  defp instance_name(index) when is_integer(index) do
    String.to_atom("#{@instance_prefix}#{index}")
  end

  # Get instance count from config or default to online schedulers
  defp get_instance_count do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:instance_count] do
      :auto -> :erlang.system_info(:schedulers_online)
      count when is_integer(count) and count > 0 -> count
      _ -> :erlang.system_info(:schedulers_online)
    end
  end

  # Get routing strategy from config
  defp get_routing_strategy do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:routing_strategy] do
      :random -> :random
      :hash -> :hash
      _ -> :hash
    end
  end

  # Keys are always routed by hash so checks for one key are serialized on one
  # instance; this is what makes accounting race-free. `:random` is accepted for
  # backwards compatibility but ignored.
  defp select_instance(payload, instance_count) do
    if protected_tables?() do
      # Protected tables can only be written by their owner, so all checks are
      # routed to the owning instance. This trades sharding for strict protection.
      instance_name(0)
    else
      routing_value = Map.get(payload, :user_id) || Map.get(payload, :request_id) || ""
      instance_name(:erlang.phash2(routing_value, instance_count))
    end
  end

  defp select_instance_for_direct(key_value, scope, instance_count) do
    if protected_tables?() do
      instance_name(0)
    else
      hash_input = "#{inspect(scope)}:#{key_value}"
      instance_name(:erlang.phash2(hash_input, instance_count))
    end
  end

  defp protected_tables? do
    PhoenixGenApi.Security.internal_table_access() == :protected
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
      started = System.monotonic_time(:microsecond)

      case effective_limits() do
        %{configured?: false} ->
          :ok

        snapshot ->
          payload = build_check_payload(request, snapshot)
          instance = select_instance(payload, snapshot.instance_count)
          result = do_check(instance, {:check_rate_limit, payload})
          emit_check_telemetry(request, instance, result, started)
          maybe_emit_exceeded(request, result)
          result
      end
    else
      :ok
    end
  end

  defp do_check(instance, message) do
    try do
      GenServer.call(instance, message, rate_limit_timeout())
    rescue
      error -> failure_result(error, :internal)
    catch
      :exit, reason -> failure_result(reason, classify_exit(reason))
    end
  end

  defp failure_result(reason, failure_class) do
    message = format_failure(reason)

    if fail_open?() do
      Logger.error(
        LogContext.line(
          "RateLimiter",
          :call_failed_fail_open,
          "call failed (fail-open)",
          LogContext.current(error: message, failure_class: failure_class)
        )
      )

      :ok
    else
      {:error, :rate_limiter_error, %{message: message, failure_class: failure_class}}
    end
  end

  defp classify_exit(:timeout), do: :timeout
  defp classify_exit({:timeout, _}), do: :timeout
  defp classify_exit(:noproc), do: :unavailable
  defp classify_exit(:shutdown), do: :unavailable
  defp classify_exit({:shutdown, _}), do: :unavailable
  defp classify_exit(_reason), do: :internal

  defp format_failure(%{__exception__: true} = error), do: Exception.message(error)
  defp format_failure(reason), do: inspect(reason)

  defp emit_check_telemetry(request, instance, result, started) do
    duration = System.monotonic_time(:microsecond) - started

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
  end

  defp maybe_emit_exceeded(request, {:error, :rate_limited, details}) do
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

  defp maybe_emit_exceeded(_request, _result), do: :ok

  # Only the key material the limiter needs is copied to the limiter process.
  # `args` is included only when a configured limit keys on a custom argument.
  defp build_check_payload(request, snapshot) do
    payload = %{
      request_id: request.request_id,
      user_id: request.user_id,
      device_id: request.device_id,
      service: request.service,
      request_type: request.request_type
    }

    payload =
      if snapshot.needs_ip? do
        Map.put(payload, :ip_address, Map.get(request, :ip_address))
      else
        payload
      end

    if snapshot.needs_args? do
      Map.put(payload, :args, request.args)
    else
      payload
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
      case effective_limits() do
        %{configured?: false} ->
          :ok

        snapshot ->
          instance = select_instance_for_direct(key_value, scope, snapshot.instance_count)
          do_check(instance, {:check_rate_limit_direct, key_value, scope, rate_limit_key})
      end
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
  @spec reset_rate_limit(String.t(), :global | api_identifier(), rate_limit_key()) ::
          :ok | {:error, term()}
  def reset_rate_limit(key_value, scope, rate_limit_key) do
    with :ok <- admin_gate(:update_rate_limit_config) do
      instance = select_instance_for_direct(key_value, scope, effective_limits().instance_count)

      case safe_admin_call(instance, {:reset_rate_limit, key_value, scope, rate_limit_key}) do
        :ok ->
          :telemetry.execute(
            [:phoenix_gen_api, :rate_limiter, :reset],
            %{},
            %{
              key: key_value,
              scope: scope,
              rate_limit_key: rate_limit_key
            }
          )

          :ok

        error ->
          error
      end
    end
  end

  @doc """
  Gets current rate limit status for a key.

  ## Returns

    A map with current usage information for all applicable rate limits.
  """
  @spec get_rate_limit_status(String.t(), :global | api_identifier(), rate_limit_key()) ::
          map() | {:error, term()}
  def get_rate_limit_status(key_value, scope, rate_limit_key) do
    instance = select_instance_for_direct(key_value, scope, effective_limits().instance_count)
    safe_admin_call(instance, {:get_rate_limit_status, key_value, scope, rate_limit_key})
  end

  @doc """
  Gets all configured rate limits.
  """
  @spec get_configured_limits() :: %{global: list(), api: list()} | {:error, term()}
  def get_configured_limits do
    # This is a global config, can query any instance
    instance = instance_name(0)
    safe_admin_call(instance, :get_configured_limits)
  end

  @doc """
  Gets the current global rate limits (may differ from config.exs if changed at runtime).

  ## Returns

    A list of global rate limit maps.

  ## Examples

      PhoenixGenApi.RateLimiter.get_global_limits()
      # => [%{key: :user_id, max_requests: 2000, window_ms: 60_000}]
  """
  @spec get_global_limits() :: [map()] | {:error, term()}
  def get_global_limits do
    # This is a global config, can query any instance
    instance = instance_name(0)
    safe_admin_call(instance, :get_global_limits)
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
  @spec set_global_limits([map()]) :: :ok | {:error, term()}
  def set_global_limits(limits) when is_list(limits) do
    with :ok <- admin_gate(:update_rate_limit_config) do
      broadcast_to_all_instances({:set_global_limits, limits})
    end
  end

  defp broadcast_to_all_instances(message) do
    instance_count = effective_limits().instance_count
    indices = if protected_tables?(), do: [0], else: Enum.to_list(0..(instance_count - 1))

    results =
      for i <- indices do
        safe_admin_call(instance_name(i), message)
      end

    case Enum.find(results, &(&1 != :ok)) do
      nil -> :ok
      error -> error
    end
  end

  defp safe_admin_call(instance, message) do
    try do
      GenServer.call(instance, message)
    rescue
      error -> {:error, {:instance_error, Exception.message(error)}}
    catch
      :exit, reason -> {:error, {:instance_unavailable, reason}}
    end
  end

  defp admin_gate(action) do
    if Application.get_env(:phoenix_gen_api, :admin_actions) == nil do
      :ok
    else
      if PhoenixGenApi.Security.admin_action_allowed?(action) do
        :ok
      else
        {:error, :admin_action_denied}
      end
    end
  end

  @doc """
  Updates rate limit configuration at runtime.
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
  @spec add_global_limit(map()) :: :ok | {:error, term()}
  def add_global_limit(limit) when is_map(limit) do
    with :ok <- admin_gate(:update_rate_limit_config) do
      broadcast_to_all_instances({:add_global_limit, limit})
    end
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
  @spec remove_global_limit(atom() | String.t()) :: :ok | {:error, term()}
  def remove_global_limit(key) do
    with :ok <- admin_gate(:update_rate_limit_config) do
      broadcast_to_all_instances({:remove_global_limit, key})
    end
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
  Returns a status snapshot for all rate limiter instances.
  """
  @spec status() :: map()
  def status do
    instance_count = instance_count()

    statuses =
      if instance_count > 0 do
        for i <- 0..(instance_count - 1) do
          case safe_admin_call(instance_name(i), :status) do
            {:error, reason} -> %{status: :error, instance_index: i, reason: reason}
            status -> status
          end
        end
      else
        []
      end

    %{status: :ok, instance_count: instance_count, instances: statuses}
  end

  @doc """
  Clears all rate limit data from ETS tables.

  Useful for testing or resetting rate limit counters.
  """
  @spec clear() :: :ok | {:error, term()}
  def clear do
    with :ok <- admin_gate(:update_rate_limit_config) do
      broadcast_to_all_instances(:clear)
    end
  end

  ### Callbacks

  @impl true
  def init(opts) do
    instance_index = Keyword.get(opts, :instance_index, 0)

    # Create the shared ETS tables. Rows are `{ {key, timestamp, unique} }` in an
    # ordered_set so a key's window can be counted with a key-prefix range scan
    # instead of copying and filtering a whole list on every check.
    case :ets.whereis(:rate_limiter_global) do
      :undefined ->
        :ets.new(:rate_limiter_global, [
          :ordered_set,
          :named_table,
          PhoenixGenApi.Security.internal_table_access(),
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    case :ets.whereis(:rate_limiter_api) do
      :undefined ->
        :ets.new(:rate_limiter_api, [
          :ordered_set,
          :named_table,
          PhoenixGenApi.Security.internal_table_access(),
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
      api_index: build_api_index(load_api_limits()),
      cleanup_interval: cleanup_interval(),
      max_keys: Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:max_rate_limit_keys],
      max_key_bytes:
        Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:max_rate_limit_key_bytes],
      ip_source: Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:ip_address_source]
    }

    validate_limit_keys(state.global_limits)
    validate_limit_keys(state.api_limits)
    publish_limits(state)

    Logger.info(
      LogContext.line(
        "RateLimiter",
        :instance_initialized,
        "instance initialized",
        instance: instance_index,
        global_limits: length(state.global_limits),
        api_limits: length(state.api_limits),
        cleanup_interval_ms: state.cleanup_interval,
        node: node()
      )
    )

    schedule_cleanup(state.cleanup_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:check_rate_limit, payload}, _from, state)
      when is_map(payload) and not is_struct(payload) do
    context = [
      request_id: payload.request_id,
      request_type: payload.request_type,
      service: payload.service,
      user_id: payload.user_id,
      node: node()
    ]

    result = LogContext.with_context(context, fn -> check_request_limits(payload, state) end)
    {:reply, result, state}
  end

  def handle_call({:check_rate_limit, request}, _from, state) do
    result =
      LogContext.with_context(LogContext.request_context(request), fn ->
        check_request_limits(request, state)
      end)

    {:reply, result, state}
  end

  def handle_call({:check_rate_limit_direct, key_value, scope, rate_limit_key}, _from, state) do
    result = check_direct_limit(key_value, scope, rate_limit_key, state)
    {:reply, result, state}
  end

  def handle_call({:reset_rate_limit, key_value, scope, rate_limit_key}, _from, state) do
    case admin_gate(:update_rate_limit_config) do
      :ok ->
        reset_limit(key_value, scope, rate_limit_key)
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
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
    case admin_gate(:update_rate_limit_config) do
      :ok -> do_set_global_limits(limits, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:add_global_limit, limit}, _from, state) do
    case admin_gate(:update_rate_limit_config) do
      :ok -> do_add_global_limit(limit, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:remove_global_limit, key}, _from, state) do
    case admin_gate(:update_rate_limit_config) do
      :ok -> do_remove_global_limit(key, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call(:clear, _from, state) do
    case admin_gate(:update_rate_limit_config) do
      :ok ->
        :ets.delete_all_objects(:rate_limiter_global)
        :ets.delete_all_objects(:rate_limiter_api)
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: :ok,
       instance_index: state.instance_index,
       global_limits: state.global_limits,
       api_limits: state.api_limits,
       cleanup_interval: state.cleanup_interval,
       ets: %{
         global: Shared.ets_table_info(:rate_limiter_global),
         api: Shared.ets_table_info(:rate_limiter_api)
       }
     }, state}
  end

  def handle_call({:update_config, config}, _from, state) do
    case admin_gate(:update_rate_limit_config) do
      :ok ->
        new_state =
          state
          |> refresh_caps()
          |> maybe_update_global_limits(config)
          |> maybe_update_api_limits(config)

        new_state = %{new_state | api_index: build_api_index(new_state.api_limits)}
        validate_limit_keys(new_state.global_limits)
        validate_limit_keys(new_state.api_limits)
        publish_limits(new_state)

        Logger.info(LogContext.event("RateLimiter", :configuration_updated, node: node()))
        {:reply, :ok, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup(state.cleanup_interval)
    maybe_start_cleanup(state)
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
    case check_global_limits(request, state.global_limits, state) do
      {:error, _reason, _details} = error ->
        error

      :ok ->
        check_api_limits(
          request,
          Map.get(state.api_index, {request.service, request.request_type}, []),
          state
        )
    end
  end

  defp check_global_limits(request, global_limits, state) do
    Enum.reduce_while(global_limits, :ok, fn limit, _acc ->
      case resolve_key(request, limit.key, state) do
        {:ok, key_value} ->
          case check_and_record(:rate_limiter_global, key_value, limit, state) do
            :ok -> {:cont, :ok}
            {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
          end

        :missing ->
          log_missing_key(limit.key, :global)
          {:cont, :ok}
      end
    end)
  end

  defp check_api_limits(request, api_limits, state) do
    Enum.reduce_while(api_limits, :ok, fn limit, _acc ->
      case resolve_key(request, limit.key, state) do
        {:ok, key_value} ->
          scope = {limit.service, limit.request_type}

          case check_and_record(:rate_limiter_api, build_api_key(key_value, scope), limit, state) do
            :ok -> {:cont, :ok}
            {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
          end

        :missing ->
          log_missing_key(limit.key, {limit.service, limit.request_type})
          {:cont, :ok}
      end
    end)
  end

  defp log_missing_key(key, scope) do
    Logger.debug(fn ->
      LogContext.line(
        "RateLimiter",
        :rate_limit_key_missing,
        "enabled limit skipped because its key source is unavailable",
        LogContext.current(rate_limit_key: key, scope: scope)
      )
    end)
  end

  defp check_direct_limit(key_value, scope, rate_limit_key, state) do
    limits =
      case scope do
        :global ->
          state.global_limits

        {service, request_type} ->
          state.api_index
          |> Map.get({service, request_type}, [])
          |> Enum.filter(fn limit -> limit.key == rate_limit_key end)
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

        case check_and_record(ets_table_for_scope(scope), ets_key, limit, state) do
          :ok -> {:cont, :ok}
          {:error, :rate_limited, details} -> {:halt, {:error, :rate_limited, details}}
        end
      end)
    end
  end

  # Sliding-window accounting with one ordered_set row per timestamp. Counting
  # and expiry use key-prefix range scans, so a check never copies or filters the
  # whole window in the caller's heap.
  defp check_and_record(table, key, limit, state) do
    key = bound_key(table, bound_key_bytes(key, state), state)
    now = System.monotonic_time(:millisecond)
    window_start = now - limit.window_ms

    delete_expired_for_key(table, key, window_start)
    current_count = count_in_window(table, key, window_start)

    if current_count >= limit.max_requests do
      retry_after_ms =
        case oldest_in_window(table, key, window_start) do
          nil -> limit.window_ms
          oldest -> max(oldest + limit.window_ms - now, 0)
        end

      details = %{
        key: key,
        max_requests: limit.max_requests,
        current_requests: current_count,
        window_ms: limit.window_ms,
        retry_after_ms: retry_after_ms,
        scope: get_scope_from_table(table, key)
      }

      Logger.warning(
        LogContext.line(
          "RateLimiter",
          :rate_limit_exceeded,
          "rate limit exceeded",
          LogContext.current(
            key: key,
            current: current_count,
            max_requests: limit.max_requests,
            window_ms: limit.window_ms,
            retry_after_ms: retry_after_ms
          )
        )
      )

      {:error, :rate_limited, details}
    else
      unique = :erlang.unique_integer([:positive, :monotonic])
      :ets.insert(table, {{key, now, unique}})
      :ok
    end
  rescue
    error in ArgumentError ->
      Logger.error(
        LogContext.line(
          "RateLimiter",
          :table_unavailable,
          "rate limit table unavailable",
          LogContext.current(error: Exception.message(error))
        )
      )

      {:error, :rate_limited,
       %{
         key: key,
         max_requests: limit.max_requests,
         current_requests: 0,
         window_ms: limit.window_ms,
         retry_after_ms: 0,
         scope: get_scope_from_table(table, key)
       }}
  end

  defp bound_key_bytes(key, %{max_key_bytes: max})
       when is_integer(max) and max > 0 and is_binary(key) do
    if byte_size(key) > max do
      :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    else
      key
    end
  end

  defp bound_key_bytes(key, _state), do: key

  defp bound_key(table, key, %{max_keys: max}) when is_integer(max) and max > 0 do
    if :ets.info(table, :size) >= max and count_all_for_key(table, key) == 0 do
      :rate_limiter_overflow
    else
      key
    end
  end

  defp bound_key(_table, key, _state), do: key

  defp count_all_for_key(table, key) do
    :ets.select_count(table, [{{{key, :_, :_}}, [], [true]}])
  end

  defp count_in_window(table, key, window_start) do
    :ets.select_count(table, [{{{key, :"$1", :_}}, [{:>, :"$1", window_start}], [true]}])
  end

  defp oldest_in_window(table, key, window_start) do
    case :ets.select(table, [{{{key, :"$1", :_}}, [{:>, :"$1", window_start}], [:"$1"]}], 1) do
      {[oldest], _continuation} -> oldest
      :"$end_of_table" -> nil
    end
  end

  defp delete_expired_for_key(table, key, window_start) do
    :ets.select_delete(table, [{{{key, :"$1", :_}}, [{:"=<", :"$1", window_start}], [true]}])
  end

  defp reset_limit(key_value, scope, _rate_limit_key) do
    table = ets_table_for_scope(scope)

    ets_key =
      case scope do
        :global -> key_value
        _ -> build_api_key(key_value, scope)
      end

    :ets.match_delete(table, {{ets_key, :_, :_}})

    Logger.info(
      LogContext.line(
        "RateLimiter",
        :rate_limit_reset,
        "rate limit reset",
        key: key_value,
        scope: scope,
        node: node()
      )
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
          Map.get(state.api_index, {service, request_type}, [])
      end

    now = System.monotonic_time(:millisecond)

    Enum.map(limits, fn limit ->
      window_start = now - limit.window_ms
      valid_count = count_in_window(table, ets_key, window_start)

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

  defp get_key_value(request, key, state) do
    case key do
      :user_id ->
        val = Map.get(request, :user_id)
        if is_binary(val), do: val, else: nil

      :device_id ->
        val = Map.get(request, :device_id)
        if is_binary(val), do: val, else: nil

      :ip_address ->
        Map.get(request, :ip_address) || Map.get(request, state.ip_source || :ip_address)

      custom_key when is_binary(custom_key) ->
        request
        |> Map.get(:args, %{})
        |> Map.get(custom_key)

      _ ->
        nil
    end
  end

  defp resolve_key(request, key, state) do
    case get_key_value(request, key, state) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :missing
    end
  end

  defp build_api_key(key_value, {service, request_type}) do
    "#{service}:#{request_type}:#{key_value}"
  end

  defp ets_table_for_scope(:global), do: :rate_limiter_global
  defp ets_table_for_scope({_service, _request_type}), do: :rate_limiter_api

  defp get_scope_from_table(:rate_limiter_global, _key), do: :global

  defp get_scope_from_table(:rate_limiter_api, key) when is_binary(key) do
    case String.split(key, ":", parts: 3) do
      [service, request_type, _key_value] -> {service, request_type}
      _ -> :global
    end
  end

  defp get_scope_from_table(:rate_limiter_api, _key), do: :global

  # Cleanup runs in a short-lived process owned by shard 0 so a sweep never
  # blocks request checks. One ordered_set range delete per table removes all
  # expired rows regardless of key.
  defp perform_cleanup(global_limits, api_limits) do
    now = System.monotonic_time(:millisecond)

    global_cleaned =
      delete_expired(:rate_limiter_global, now - max_window(global_limits))

    api_cleaned = delete_expired(:rate_limiter_api, now - max_window(api_limits))
    global_cleaned + api_cleaned
  rescue
    _error in ArgumentError -> 0
  end

  defp delete_expired(table, cutoff) do
    :ets.select_delete(table, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
  end

  defp max_window([]), do: @default_cleanup_interval

  defp max_window(limits) do
    limits
    |> Enum.map(& &1.window_ms)
    |> Enum.max(fn -> @default_cleanup_interval end)
  end

  defp build_api_index(api_limits) do
    Enum.group_by(api_limits, fn limit -> {limit.service, limit.request_type} end)
  end

  defp needs_args?(limits) do
    Enum.any?(limits, fn limit -> is_binary(limit.key) end)
  end

  defp needs_ip?(limits) do
    Enum.any?(limits, fn limit -> limit.key == :ip_address end)
  end

  defp validate_limit_keys(limits) do
    Enum.each(limits, fn limit ->
      if limit.key == :ip_address and
           Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:ip_address_source] == nil do
        Logger.warning(
          LogContext.line(
            "RateLimiter",
            :unsupported_key_source,
            ":ip_address limits cannot be evaluated unless :ip_address_source is configured",
            LogContext.current(rate_limit_key: :ip_address)
          )
        )
      end
    end)
  end

  defp do_set_global_limits(limits, state) do
    state = refresh_caps(state)

    Logger.info(
      LogContext.line(
        "RateLimiter",
        :global_limits_replaced,
        "global limits replaced",
        count: length(limits),
        node: node()
      )
    )

    new_state = %{state | global_limits: limits}
    validate_limit_keys(limits)
    publish_limits(new_state)
    {:reply, :ok, new_state}
  end

  defp do_add_global_limit(limit, state) do
    state = refresh_caps(state)
    key = Map.get(limit, :key)

    new_limits =
      state.global_limits
      |> Enum.reject(fn l -> Map.get(l, :key) == key end)
      |> Enum.concat([limit])

    Logger.info(
      LogContext.line(
        "RateLimiter",
        :global_limit_upserted,
        "global limit added/updated",
        key: Map.get(limit, :key),
        max_requests: Map.get(limit, :max_requests),
        window_ms: Map.get(limit, :window_ms),
        node: node()
      )
    )

    new_state = %{state | global_limits: new_limits}
    publish_limits(new_state)
    {:reply, :ok, new_state}
  end

  defp do_remove_global_limit(key, state) do
    state = refresh_caps(state)
    new_limits = Enum.reject(state.global_limits, fn l -> Map.get(l, :key) == key end)

    Logger.info(
      LogContext.line(
        "RateLimiter",
        :global_limit_removed,
        "global limit removed",
        key: key,
        remaining: length(new_limits),
        node: node()
      )
    )

    new_state = %{state | global_limits: new_limits}
    publish_limits(new_state)
    {:reply, :ok, new_state}
  end

  defp refresh_caps(state) do
    config = Application.get_env(:phoenix_gen_api, :rate_limiter, [])

    %{
      state
      | max_keys: config[:max_rate_limit_keys],
        max_key_bytes: config[:max_rate_limit_key_bytes],
        ip_source: config[:ip_address_source]
    }
  end

  defp publish_limits(state) do
    :persistent_term.put(@limits_key, %{
      configured?: state.global_limits != [] or state.api_limits != [],
      instance_count: get_instance_count(),
      needs_args?: needs_args?(state.global_limits) or needs_args?(state.api_limits),
      needs_ip?: needs_ip?(state.global_limits) or needs_ip?(state.api_limits),
      max_keys: state.max_keys,
      max_key_bytes: state.max_key_bytes,
      ip_source: state.ip_source
    })
  end

  defp effective_limits do
    :persistent_term.get(@limits_key, %{
      configured?: true,
      instance_count: get_instance_count(),
      needs_args?: true,
      needs_ip?: true,
      max_keys: nil,
      max_key_bytes: nil,
      ip_source: nil
    })
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  # Only shard 0 sweeps the shared tables, and it does so off the reply path.
  defp maybe_start_cleanup(%{instance_index: index}) when index != 0, do: :ok

  defp maybe_start_cleanup(state) do
    global_limits = state.global_limits
    api_limits = state.api_limits

    spawn(fn ->
      start_time = System.monotonic_time(:microsecond)
      cleaned_count = perform_cleanup(global_limits, api_limits)
      duration = System.monotonic_time(:microsecond) - start_time

      :telemetry.execute(
        [:phoenix_gen_api, :rate_limiter, :cleanup],
        %{duration_us: duration, cleaned_entries: cleaned_count},
        %{
          global_limits_count: length(global_limits),
          api_limits_count: length(api_limits)
        }
      )
    end)

    :ok
  end

  defp load_global_limits do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:global_limits] do
      nil -> []
      limits when is_list(limits) -> limits
      _ -> []
    end
  end

  defp load_api_limits do
    case Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:api_limits] do
      nil -> []
      limits when is_list(limits) -> limits
      _ -> []
    end
  end

  defp enabled? do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:enabled] != false
  end

  defp fail_open? do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:fail_open] != false
  end

  defp rate_limit_timeout do
    Application.get_env(:phoenix_gen_api, :rate_limiter, [])[:timeout] || 1000
  end

  defp cleanup_interval do
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
