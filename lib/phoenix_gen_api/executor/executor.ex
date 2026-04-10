defmodule PhoenixGenApi.Executor do
  @moduledoc """
  The core execution engine of PhoenixGenApi.

  This module is responsible for taking a `Request` struct, looking up its
  corresponding `FunConfig`, and executing the function call according to the
  configuration. It handles synchronous, asynchronous, and streaming responses.

  ## Worker Pools

  Async and stream calls now use dedicated worker pools instead of spawning
  unlimited processes. This provides better resource management and prevents
  system overload.

  ## Error Handling

  All execution paths catch errors, exits, and throws, converting them to
  safe error responses. Internal error details are only exposed when
  `:detail_error` is enabled in configuration.

  ## Node Fallback

  When executing on remote nodes, if the primary node fails, the executor
  will attempt to fall back to another available node (if configured).

  ## Retry

  When a request execution fails (returns `{:error, _}` or `{:error, _, _}`),
  the executor can retry according to the `retry` field in `FunConfig`.

  - **`{:same_node, n}`**: Retries the request on the same node(s) that were
    originally selected by the `choose_node_mode` strategy. Useful when the
    failure might be transient (e.g., temporary network glitch).

  - **`{:all_nodes, n}`**: On each retry, fetches the full list of available
    nodes and tries all of them. Useful when a node might be down and you
    want to try other nodes.

  - **Local execution**: For `nodes: :local`, both `:same_node` and
    `:all_nodes` retry on the same local machine since there's only one node.

  - **Shorthand**: A plain number (e.g., `3`) is equivalent to
    `{:all_nodes, 3}`.

  - **`nil`**: No retry (default, backward compatible).

  Retry attempts emit telemetry events at `[:phoenix_gen_api, :executor, :retry]`
  with measurements `%{attempt: n}` and metadata
  `%{mode: :same_node | :all_nodes, type: :local | :remote}`.
  """

  alias PhoenixGenApi.Structs.{Request, FunConfig, Response}
  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.RateLimiter

  require Logger

  @default_rpc_timeout 5000

  @doc """
  Attaches a telemetry handler to executor events.

  ## Events

  - `[:phoenix_gen_api, :executor, :request, :start]` - Emitted when request execution starts
  - `[:phoenix_gen_api, :executor, :request, :stop]` - Emitted when request execution completes
  - `[:phoenix_gen_api, :executor, :request, :exception]` - Emitted when request execution fails

  ## Examples

      :telemetry.attach(
        "my-executor-handler",
        [:phoenix_gen_api, :executor, :request, :stop],
        fn event, measurements, metadata, config ->
          ...
        end,
        %{}
      )
  """
  def attach_telemetry(handler_id, function, config \\ %{})
      when is_binary(handler_id) and is_function(function, 4) do
    :telemetry.attach(
      "#{handler_id}-start",
      [:phoenix_gen_api, :executor, :request, :start],
      function,
      config
    )

    :telemetry.attach(
      "#{handler_id}-stop",
      [:phoenix_gen_api, :executor, :request, :stop],
      function,
      config
    )

    :telemetry.attach(
      "#{handler_id}-exception",
      [:phoenix_gen_api, :executor, :request, :exception],
      function,
      config
    )

    :ok
  end

  @doc """
  Detaches telemetry handlers by ID.
  """
  def detach_telemetry(handler_id) when is_binary(handler_id) do
    :telemetry.detach("#{handler_id}-start")
    :telemetry.detach("#{handler_id}-stop")
    :telemetry.detach("#{handler_id}-exception")
    :ok
  end

  @doc """
  Executes a request from a map of parameters.

  This is a convenience function that decodes the params into a `Request` struct
  before calling `execute!/1`.
  """
  @spec execute_params!(map()) :: Response.t()
  def execute_params!(params) do
    request = Request.decode!(params)
    execute!(request)
  end

  @doc """
  Executes a request.
  """
  @spec execute!(Request.t()) :: Response.t()
  def execute!(request = %Request{}) do
    start_time = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:phoenix_gen_api, :executor, :request, :start],
      %{system_time: System.system_time()},
      %{
        request_id: request.request_id,
        request_type: request.request_type,
        service: request.service,
        user_id: request.user_id
      }
    )

    try do
      version = request.version || "0.0.0"

      result =
        case ConfigDb.get(request.service, request.request_type, version) do
          {:ok, fun_config} ->
            execute_with_config!(request, fun_config)

          {:error, :not_found} ->
            Logger.warning(
              "PhoenixGenApi.Executor, unsupported function: #{request.request_type} version #{version}"
            )

            Response.error_response(
              request.request_id,
              "unsupported function: #{request.request_type} version #{version}"
            )

          {:error, :disabled} ->
            Logger.warning(
              "PhoenixGenApi.Executor, disabled function: #{request.request_type} version #{version}"
            )

            Response.error_response(
              request.request_id,
              "disabled function: #{request.request_type} version #{version}"
            )
        end

      duration = System.monotonic_time(:microsecond) - start_time

      {success, async} =
        case result do
          %Response{success: s, async: a} -> {s, a}
          _ -> {true, false}
        end

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :request, :stop],
        %{duration_us: duration},
        %{
          request_id: request.request_id,
          request_type: request.request_type,
          service: request.service,
          user_id: request.user_id,
          success: success,
          async: async
        }
      )

      result
    rescue
      e ->
        duration = System.monotonic_time(:microsecond) - start_time

        :telemetry.execute(
          [:phoenix_gen_api, :executor, :request, :exception],
          %{duration_us: duration},
          %{
            request_id: request.request_id,
            request_type: request.request_type,
            service: request.service,
            user_id: request.user_id,
            kind: :error,
            reason: Exception.message(e),
            stacktrace: __STACKTRACE__
          }
        )

        reraise e, __STACKTRACE__
    end
  end

  def execute_with_config!(request = %Request{}, fun_config = %FunConfig{}) do
    Logger.debug(
      "PhoenixGenApi.Executor, executing request: #{request.request_id}, " <>
        "response_type: #{fun_config.response_type}"
    )

    # Check rate limits before permission check
    case RateLimiter.check_rate_limit(request) do
      :ok ->
        :ok

      {:error, :rate_limited, details} ->
        Logger.warning(
          "PhoenixGenApi.Executor, rate limit exceeded for request: #{request.request_id}, " <>
            "details: #{inspect(details)}"
        )

        retry_after_ms = Map.get(details, :retry_after_ms, 0)

        Response.error_response(
          request.request_id,
          "Rate limit exceeded. Please retry after #{div(retry_after_ms, 1000)} seconds.",
          true
        )
        |> Map.put(:can_retry, true)
        |> then(& &1)

      {:error, :rate_limiter_error, error_details} ->
        # Fail-open: log error but allow request to proceed
        Logger.error(
          "PhoenixGenApi.Executor, rate limiter error: #{inspect(error_details)}, allowing request"
        )

        :ok
    end

    Permission.check_permission!(request, fun_config)

    case fun_config.response_type do
      :sync -> sync_call(request, fun_config)
      :async -> async_call(request, fun_config)
      :none -> async_call(request, fun_config)
      :stream -> stream_call(request, fun_config)
    end
  end

  def sync_call(request, fun_config) do
    try do
      do_call(request, fun_config)
    rescue
      e ->
        Logger.error(
          "PhoenixGenApi.Executor, sync_call rescued: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        Response.error_response(request.request_id, get_error_message(e))
    catch
      :exit, reason ->
        Logger.error("PhoenixGenApi.Executor, sync_call exited: #{inspect(reason)}")
        Response.error_response(request.request_id, get_error_message(reason))

      :throw, reason ->
        Logger.error("PhoenixGenApi.Executor, sync_call threw: #{inspect(reason)}")
        Response.error_response(request.request_id, get_error_message(reason))

      kind, reason ->
        Logger.error(
          "PhoenixGenApi.Executor, sync_call caught #{inspect(kind)}: #{inspect(reason)}"
        )

        Response.error_response(request.request_id, get_error_message(reason))
    end
  end

  defp do_call(request, fun_config) do
    args = ArgumentHandler.convert_args!(fun_config, request)
    {mod, fun, predefined_args} = fun_config.mfa

    final_args = predefined_args ++ args ++ info_args(request, fun_config)
    retry_config = FunConfig.normalize_retry(fun_config.retry)

    result =
      if FunConfig.is_local_service?(fun_config) do
        execute_local_with_retry(mod, fun, final_args, fun_config.timeout, retry_config)
      else
        execute_remote_with_retry(mod, fun, final_args, fun_config, request, retry_config)
      end

    handle_call_result(result, request.request_id)
  end

  defp execute_local(mod, fun, args, timeout) do
    task = Task.async(fn -> apply(mod, fun, args) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, "local execution timed out after #{timeout}ms"}
      {:exit, reason} -> {:error, "local execution failed: #{inspect(reason)}"}
    end
  end

  # Retry helpers for local execution

  defp execute_local_with_retry(mod, fun, args, timeout, retry_config) do
    result = execute_local(mod, fun, args, timeout)
    apply_local_retry(result, mod, fun, args, timeout, retry_config)
  end

  defp apply_local_retry(result, mod, fun, args, timeout, retry_config) do
    if is_retryable_error?(result) and has_retry_remaining?(retry_config) do
      {mode, n} = retry_config

      Logger.info("PhoenixGenApi.Executor, local retry (#{mode}), #{n} attempts remaining")

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n},
        %{mode: mode, type: :local}
      )

      new_result = execute_local(mod, fun, args, timeout)
      apply_local_retry(new_result, mod, fun, args, timeout, {mode, n - 1})
    else
      result
    end
  end

  # Retry helpers for remote execution

  defp execute_remote_with_retry(mod, fun, args, fun_config, request, retry_config) do
    nodes = get_nodes_list(fun_config, request)
    rpc_timeout = get_rpc_timeout(fun_config)

    result =
      execute_remote_with_fallback(nodes, mod, fun, args, rpc_timeout, request.request_id, nil)

    apply_remote_retry(
      result,
      mod,
      fun,
      args,
      fun_config,
      request,
      rpc_timeout,
      nodes,
      retry_config
    )
  end

  defp apply_remote_retry(
         result,
         mod,
         fun,
         args,
         fun_config,
         request,
         rpc_timeout,
         original_nodes,
         {:same_node, n}
       )
       when n > 0 do
    if is_retryable_error?(result) do
      Logger.info("PhoenixGenApi.Executor, remote retry (same_node), #{n} attempts remaining")

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n},
        %{mode: :same_node, type: :remote, nodes: original_nodes}
      )

      # Retry on the same nodes that were originally selected
      new_result =
        execute_remote_with_fallback(
          original_nodes,
          mod,
          fun,
          args,
          rpc_timeout,
          request.request_id,
          nil
        )

      apply_remote_retry(
        new_result,
        mod,
        fun,
        args,
        fun_config,
        request,
        rpc_timeout,
        original_nodes,
        {:same_node, n - 1}
      )
    else
      result
    end
  end

  defp apply_remote_retry(
         result,
         mod,
         fun,
         args,
         fun_config,
         request,
         rpc_timeout,
         _original_nodes,
         {:all_nodes, n}
       )
       when n > 0 do
    if is_retryable_error?(result) do
      # Retry on ALL available nodes
      all_nodes = get_all_nodes_list(fun_config, request)

      Logger.info("PhoenixGenApi.Executor, remote retry (all_nodes), #{n} attempts remaining")

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n},
        %{mode: :all_nodes, type: :remote, nodes: all_nodes}
      )

      new_result =
        execute_remote_with_fallback(
          all_nodes,
          mod,
          fun,
          args,
          rpc_timeout,
          request.request_id,
          nil
        )

      apply_remote_retry(
        new_result,
        mod,
        fun,
        args,
        fun_config,
        request,
        rpc_timeout,
        all_nodes,
        {:all_nodes, n - 1}
      )
    else
      result
    end
  end

  defp apply_remote_retry(
         result,
         _mod,
         _fun,
         _args,
         _fun_config,
         _request,
         _rpc_timeout,
         _original_nodes,
         _retry_config
       ) do
    result
  end

  defp is_retryable_error?({:error, _}), do: true
  defp is_retryable_error?({:error, _, _}), do: true
  defp is_retryable_error?(_), do: false

  defp has_retry_remaining?({:same_node, n}) when n > 0, do: true
  defp has_retry_remaining?({:all_nodes, n}) when n > 0, do: true
  defp has_retry_remaining?(_), do: false

  defp execute_remote_with_fallback([], _mod, _fun, _args, _timeout, _request_id, last_error) do
    Logger.error("PhoenixGenApi.Executor, no nodes available for remote execution")
    last_error || {:error, "no target nodes available"}
  end

  defp execute_remote_with_fallback(
         [node | remaining_nodes],
         mod,
         fun,
         args,
         timeout,
         request_id,
         _last_error
       ) do
    case :rpc.call(node, mod, fun, args, timeout) do
      {:badrpc, :timeout} ->
        Logger.warning(
          "PhoenixGenApi.Executor, RPC timeout on node #{inspect(node)}, trying fallback"
        )

        execute_remote_with_fallback(
          remaining_nodes,
          mod,
          fun,
          args,
          timeout,
          request_id,
          {:error, :timeout}
        )

      {:badrpc, reason} ->
        Logger.warning(
          "PhoenixGenApi.Executor, RPC failed on node #{inspect(node)}: #{inspect(reason)}, trying fallback"
        )

        execute_remote_with_fallback(
          remaining_nodes,
          mod,
          fun,
          args,
          timeout,
          request_id,
          {:error, reason}
        )

      result ->
        result
    end
  end

  defp get_nodes_list(fun_config, request) do
    config_with_nodes =
      case fun_config.nodes do
        {m, f, a} ->
          case apply(m, f, a) do
            nodes when is_list(nodes) ->
              %{fun_config | nodes: nodes}

            other ->
              Logger.error("PhoenixGenApi.Executor, invalid nodes from MFA: #{inspect(other)}")
              %{fun_config | nodes: []}
          end

        nodes when is_list(nodes) ->
          fun_config

        _ ->
          Logger.error(
            "PhoenixGenApi.Executor, invalid nodes configuration: #{inspect(fun_config.nodes)}"
          )

          %{fun_config | nodes: []}
      end

    case config_with_nodes.choose_node_mode do
      :random ->
        [Enum.random(config_with_nodes.nodes)]

      :hash ->
        hash_order = :erlang.phash2(request.request_id, length(config_with_nodes.nodes))
        [Enum.at(config_with_nodes.nodes, hash_order)]

      {:hash, hash_key} ->
        value = Map.get(request.args, hash_key) || Map.get(request, hash_key)

        if value do
          hash_order = :erlang.phash2(value, length(config_with_nodes.nodes))
          [Enum.at(config_with_nodes.nodes, hash_order)]
        else
          Logger.error(
            "PhoenixGenApi.Executor, hash key #{inspect(hash_key)} not found in request"
          )

          config_with_nodes.nodes
        end

      :round_robin ->
        config_with_nodes.nodes

      _ ->
        Logger.error(
          "PhoenixGenApi.Executor, invalid choose_node_mode: #{inspect(config_with_nodes.choose_node_mode)}"
        )

        config_with_nodes.nodes
    end
  end

  defp get_all_nodes_list(fun_config, _request) do
    config_with_nodes =
      case fun_config.nodes do
        {m, f, a} ->
          case apply(m, f, a) do
            nodes when is_list(nodes) ->
              %{fun_config | nodes: nodes}

            other ->
              Logger.error("PhoenixGenApi.Executor, invalid nodes from MFA: #{inspect(other)}")
              %{fun_config | nodes: []}
          end

        nodes when is_list(nodes) ->
          fun_config

        _ ->
          Logger.error(
            "PhoenixGenApi.Executor, invalid nodes configuration: #{inspect(fun_config.nodes)}"
          )

          %{fun_config | nodes: []}
      end

    config_with_nodes.nodes
  end

  defp get_rpc_timeout(fun_config) do
    case fun_config.timeout do
      :infinity -> @default_rpc_timeout * 5
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_rpc_timeout
    end
  end

  defp info_args(request, fun_config) do
    if fun_config.request_info do
      request_info = %{
        request_id: request.request_id,
        user_id: request.user_id,
        device_id: request.device_id
      }

      case fun_config.response_type do
        :stream -> [Map.put(request_info, :stream_pid, self())]
        _ -> [request_info]
      end
    else
      []
    end
  rescue
    e ->
      Logger.error("PhoenixGenApi.Executor, failed to build info_args: #{Exception.message(e)}")
      []
  end

  defp handle_call_result({:error, reason}, request_id) do
    Response.error_response(request_id, get_error_message(reason))
  end

  defp handle_call_result({:error, reason, _metadata}, request_id) do
    Response.error_response(request_id, get_error_message(reason))
  end

  defp handle_call_result({:ok, result}, request_id) do
    Response.sync_response(request_id, result)
  end

  # action as successful request.
  defp handle_call_result(result, request_id) do
    Response.sync_response(request_id, result)
  end

  defp async_call(request, fun_config) do
    receiver = self()

    # Use worker pool for async execution
    task = fn ->
      try do
        result = sync_call(request, fun_config)

        if fun_config.response_type != :none do
          send(receiver, {:async_call, result})
        end
      catch
        kind, reason ->
          Logger.error(
            "PhoenixGenApi.Executor, async_call task failed: #{inspect(kind)}: #{inspect(reason)}"
          )

          error_response = Response.error_response(request.request_id, "Async execution failed")
          send(receiver, {:async_call, error_response})
      end
    end

    case PhoenixGenApi.WorkerPool.execute_async(:async_pool, task) do
      :ok ->
        if fun_config.response_type != :none do
          Response.async_response(request.request_id)
        else
          {:ok, :no_response}
        end

      {:error, :queue_full} ->
        Logger.error(
          "PhoenixGenApi.Executor, async_call failed: worker pool queue full for request #{request.request_id}"
        )

        Response.error_response(request.request_id, "Service temporarily unavailable", true)
    end
  end

  defp stream_call(request = %Request{}, fun_config = %FunConfig{}) do
    receiver = self()
    request_id = request.request_id

    # Use worker pool for stream execution
    task = fn ->
      try do
        case StreamCall.start_link(%{
               request: request,
               fun_config: fun_config,
               receiver: receiver
             }) do
          {:ok, pid} ->
            # Store the stream PID for potential cancellation
            send(receiver, {:stream_started, request_id, pid})

            # Wait for stream to complete with timeout
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
            after
              fun_config.timeout ->
                Logger.warning(
                  "PhoenixGenApi.Executor, stream_call timed out after #{fun_config.timeout}ms"
                )

                GenServer.stop(pid, :timeout)
            end

          {:error, reason} ->
            Logger.error(
              "PhoenixGenApi.Executor, stream_call start_link failed: #{inspect(reason)}"
            )

            send(
              receiver,
              {:stream_response, Response.error_response(request_id, "Failed to start stream")}
            )
        end
      catch
        kind, reason ->
          Logger.error(
            "PhoenixGenApi.Executor, stream_call task failed: #{inspect(kind)}: #{inspect(reason)}"
          )

          send(
            receiver,
            {:stream_response, Response.error_response(request_id, "Stream execution failed")}
          )
      end
    end

    case PhoenixGenApi.WorkerPool.execute_async(:async_pool, task) do
      :ok ->
        receive do
          {:stream_started, ^request_id, pid} ->
            Process.put({:phoenix_gen_api, :stream_call_pid, request_id}, pid)
            Response.stream_response(request_id, :init)

          {:stream_response, error_response} ->
            error_response
        after
          5000 ->
            Logger.error(
              "PhoenixGenApi.Executor, stream_call timeout waiting for stream to start"
            )

            Response.error_response(request_id, "Failed to start stream")
        end

      {:error, :queue_full} ->
        Logger.error(
          "PhoenixGenApi.Executor, stream_call failed: worker pool queue full for request #{request_id}"
        )

        Response.error_response(request_id, "Service temporarily unavailable", true)
    end
  end

  defp get_error_message(reason) do
    if Application.get_env(:phoenix_gen_api, :detail_error, false) do
      "Internal Server Error: #{inspect(reason)}"
    else
      "Internal Server Error"
    end
  end

  @doc """
  Executes a request with a custom timeout.

  This function wraps `execute!/1` with a timeout to prevent long-running
  requests from blocking the caller indefinitely.

  ## Parameters

    - `request` - The request to execute
    - `timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    - `Response.t()` - The execution result or timeout error
  """
  @spec execute_with_timeout!(Request.t(), non_neg_integer()) :: Response.t()
  def execute_with_timeout!(request, timeout \\ @default_rpc_timeout) do
    task = Task.async(fn -> execute!(request) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        Response.error_response(request.request_id, "Request timed out after #{timeout}ms")

      {:exit, reason} ->
        Response.error_response(request.request_id, "Request failed: #{inspect(reason)}")
    end
  end
end
