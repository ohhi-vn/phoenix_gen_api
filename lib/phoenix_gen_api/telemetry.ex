defmodule PhoenixGenApi.Telemetry do
  @moduledoc """
  Telemetry integration for PhoenixGenApi.

  This module provides a central place to discover, attach to, and
  handle all telemetry events emitted by PhoenixGenApi.

  ## Events

  ### Executor

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:phoenix_gen_api, :executor, :request, :start]` | `%{system_time: integer()}` | `%{request_id: String.t(), request_type: String.t(), service: String.t(), user_id: String.t()}` |
  | `[:phoenix_gen_api, :executor, :request, :stop]` | `%{duration_us: integer()}` | `%{request_id: String.t(), request_type: String.t(), service: String.t(), user_id: String.t(), success: boolean(), async: boolean()}` |
  | `[:phoenix_gen_api, :executor, :request, :exception]` | `%{duration_us: integer()}` | `%{request_id: String.t(), request_type: String.t(), service: String.t(), user_id: String.t(), kind: atom(), reason: String.t(), stacktrace: Exception.stacktrace()}` |
  | `[:phoenix_gen_api, :executor, :retry]` | `%{attempt: non_neg_integer()}` | `%{mode: :same_node or :all_nodes, type: :local or :remote}` + optional `nodes: list()` for remote retries |

  ### Rate Limiter

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:phoenix_gen_api, :rate_limiter, :check]` | `%{duration_us: integer()}` | `%{request_id: String.t(), user_id: String.t(), service: String.t(), request_type: String.t(), result: :ok or {:error, :rate_limited, map()}}` |
  | `[:phoenix_gen_api, :rate_limiter, :exceeded]` | `%{retry_after_ms: non_neg_integer()}` | `%{key: String.t(), scope: :global or {String.t(), String.t()}, max_requests: non_neg_integer(), current_requests: non_neg_integer(), request_id: String.t(), user_id: String.t()}` |
  | `[:phoenix_gen_api, :rate_limiter, :reset]` | `%{}` | `%{key: String.t(), scope: atom(), rate_limit_key: atom()}` |
  | `[:phoenix_gen_api, :rate_limiter, :cleanup]` | `%{duration_us: integer(), cleaned_entries: non_neg_integer()}` | `%{global_limits_count: non_neg_integer(), api_limits_count: non_neg_integer()}` |

  ### Hooks

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:phoenix_gen_api, :hook, :before, :start]` | `%{system_time: integer()}` | `%{module: module(), function: atom(), type: :before}` |
  | `[:phoenix_gen_api, :hook, :before, :stop]` | `%{duration_us: integer()}` | `%{module: module(), function: atom(), type: :before}` |
  | `[:phoenix_gen_api, :hook, :before, :exception]` | `%{duration_us: integer()}` | `%{module: module(), function: atom(), type: :before, kind: atom(), reason: String.t(), stacktrace: Exception.stacktrace()}` |
  | `[:phoenix_gen_api, :hook, :after, :start]` | `%{system_time: integer()}` | `%{module: module(), function: atom(), type: :after}` |
  | `[:phoenix_gen_api, :hook, :after, :stop]` | `%{duration_us: integer()}` | `%{module: module(), function: atom(), type: :after}` |
  | `[:phoenix_gen_api, :hook, :after, :exception]` | `%{duration_us: integer()}` | `%{module: module(), function: atom(), type: :after, kind: atom(), reason: String.t(), stacktrace: Exception.stacktrace()}` |

  ### Worker Pool

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:phoenix_gen_api, :worker_pool, :task, :start]` | `%{system_time: integer()}` | `%{pool_name: atom()}` |
  | `[:phoenix_gen_api, :worker_pool, :task, :stop]` | `%{duration_us: integer()}` | `%{pool_name: atom()}` |
  | `[:phoenix_gen_api, :worker_pool, :task, :exception]` | `%{duration_us: integer()}` | `%{pool_name: atom(), kind: atom(), reason: term(), stacktrace: Exception.stacktrace()}` |
  | `[:phoenix_gen_api, :worker_pool, :circuit_breaker, :open]` | `%{}` | `%{pool_name: atom(), consecutive_failures: non_neg_integer()}` |
  | `[:phoenix_gen_api, :worker_pool, :circuit_breaker, :close]` | `%{}` | `%{pool_name: atom()}` |

  ### Config Cache

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:phoenix_gen_api, :config, :pull, :start]` | `%{system_time: integer()}` | `%{service: String.t() \| atom()}` |
  | `[:phoenix_gen_api, :config, :pull, :stop]` | `%{duration_us: integer(), count: non_neg_integer()}` | `%{service: String.t() \| atom(), version: String.t() \| nil}` |
  | `[:phoenix_gen_api, :config, :push]` | `%{count: non_neg_integer()}` | `%{service: String.t() \| atom(), version: String.t()}` |
  | `[:phoenix_gen_api, :config, :add]` | `%{}` | `%{service: String.t() \| atom(), request_type: String.t(), version: String.t()}` |
  | `[:phoenix_gen_api, :config, :batch_add]` | `%{count: non_neg_integer()}` | `%{service: String.t() \| atom()}` |
  | `[:phoenix_gen_api, :config, :delete]` | `%{}` | `%{service: String.t() \| atom(), request_type: String.t(), version: String.t()}` |
  | `[:phoenix_gen_api, :config, :clear]` | `%{}` | `%{service: atom(), request_type: atom(), version: atom()}` |
  | `[:phoenix_gen_api, :config, :disable]` | `%{}` | `%{service: String.t() \| atom(), request_type: String.t(), version: String.t()}` |
  | `[:phoenix_gen_api, :config, :enable]` | `%{}` | `%{service: String.t() \| atom(), request_type: String.t(), version: String.t()}` |

  ## Usage

      # Attach a handler to all events
      PhoenixGenApi.Telemetry.attach_all("my-handler", &MyApp.handle_event/4)

      # Attach only to executor events
      PhoenixGenApi.Telemetry.attach_executor("my-handler", &MyApp.handle_event/4)

      # Attach the built-in debug logger
      PhoenixGenApi.Telemetry.attach_default_logger()

      # Detach everything for a handler ID
      PhoenixGenApi.Telemetry.detach_all("my-handler")
  """

  require Logger

  @executor_events [
    [:phoenix_gen_api, :executor, :request, :start],
    [:phoenix_gen_api, :executor, :request, :stop],
    [:phoenix_gen_api, :executor, :request, :exception],
    [:phoenix_gen_api, :executor, :retry]
  ]

  @rate_limiter_events [
    [:phoenix_gen_api, :rate_limiter, :check],
    [:phoenix_gen_api, :rate_limiter, :exceeded],
    [:phoenix_gen_api, :rate_limiter, :reset],
    [:phoenix_gen_api, :rate_limiter, :cleanup]
  ]

  @hook_events [
    [:phoenix_gen_api, :hook, :before, :start],
    [:phoenix_gen_api, :hook, :before, :stop],
    [:phoenix_gen_api, :hook, :before, :exception],
    [:phoenix_gen_api, :hook, :after, :start],
    [:phoenix_gen_api, :hook, :after, :stop],
    [:phoenix_gen_api, :hook, :after, :exception]
  ]

  @worker_pool_events [
    [:phoenix_gen_api, :worker_pool, :task, :start],
    [:phoenix_gen_api, :worker_pool, :task, :stop],
    [:phoenix_gen_api, :worker_pool, :task, :exception],
    [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
    [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close]
  ]

  @config_events [
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

  @all_events @executor_events ++
                @rate_limiter_events ++ @hook_events ++ @worker_pool_events ++ @config_events

  @doc """
  Returns the full list of telemetry events emitted by PhoenixGenApi.
  """
  @spec list_events() :: [list(atom())]
  def list_events, do: @all_events

  @doc """
  Attaches a handler function to all PhoenixGenApi telemetry events.
  """
  @spec attach_all(String.t(), function(), map()) :: :ok
  def attach_all(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @all_events, function, config)
  end

  @doc """
  Detaches all handlers for the given handler ID.
  """
  @spec detach_all(String.t()) :: :ok
  def detach_all(handler_id) when is_binary(handler_id) do
    Enum.each(@all_events, fn event ->
      :telemetry.detach("#{handler_id}-#{join(event)}")
    end)
  end

  @doc """
  Attaches a handler to executor events.
  """
  @spec attach_executor(String.t(), function(), map()) :: :ok
  def attach_executor(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @executor_events, function, config)
  end

  @doc """
  Attaches a handler to rate limiter events.
  """
  @spec attach_rate_limiter(String.t(), function(), map()) :: :ok
  def attach_rate_limiter(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @rate_limiter_events, function, config)
  end

  @doc """
  Attaches a handler to hook events.
  """
  @spec attach_hooks(String.t(), function(), map()) :: :ok
  def attach_hooks(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @hook_events, function, config)
  end

  @doc """
  Attaches a handler to worker pool events.
  """
  @spec attach_worker_pool(String.t(), function(), map()) :: :ok
  def attach_worker_pool(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @worker_pool_events, function, config)
  end

  @doc """
  Attaches a handler to config cache events.
  """
  @spec attach_config(String.t(), function(), map()) :: :ok
  def attach_config(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    attach_many(handler_id, @config_events, function, config)
  end

  @doc """
  Attaches a handler to a list of events.
  """
  @spec attach_many(String.t(), [list(atom())], function(), map()) :: :ok
  def attach_many(handler_id, events, function, config \\ %{})
      when is_binary(handler_id) and is_list(events) and is_function(function, 4) do
    Enum.each(events, fn event ->
      :telemetry.attach("#{handler_id}-#{join(event)}", event, function, config)
    end)
  end

  @doc """
  Attaches a default console logger that logs all telemetry events at debug level.
  """
  @spec attach_default_logger(String.t()) :: :ok
  def attach_default_logger(handler_id \\ "phoenix-gen-api-default-logger") do
    attach_all(handler_id, &default_logger/4)
  end

  @doc """
  Detaches the default console logger.
  """
  @spec detach_default_logger(String.t()) :: :ok
  def detach_default_logger(handler_id \\ "phoenix-gen-api-default-logger") do
    detach_all(handler_id)
  end

  @doc false
  @spec default_logger(list(atom()), map(), map(), any()) :: :ok
  def default_logger(event, measurements, metadata, _config) do
    Logger.debug("""
    [PhoenixGenApi.Telemetry] event=#{inspect(event)}
      measurements=#{inspect(measurements)}
      metadata=#{inspect(metadata)}\
    """)
  end

  @doc """
  Emits a telemetry event. Thin wrapper around `:telemetry.execute/3`.
  """
  @spec execute(list(atom()), map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc """
  Wraps a function in a telemetry span. Thin wrapper around `:telemetry.span/3`.
  """
  @spec span(list(atom()), map(), function()) :: any()
  def span(event, metadata, fun) when is_list(event) and is_function(fun) do
    :telemetry.span(event, metadata, fun)
  end

  defp join(event) do
    event |> Enum.map_join("-", &to_string/1)
  end
end
