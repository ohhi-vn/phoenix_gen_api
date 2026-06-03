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
  alias PhoenixGenApi.Hooks
  alias PhoenixGenApi.NodeSelector

  require Logger

  # Retry state struct to group parameters and reduce function arity
  defmodule RetryState do
    @moduledoc """
    Retry state for executor retry operations.

    This struct groups parameters that were previously passed individually
    to reduce function arity and improve code maintainability.
    """
    @type t :: %__MODULE__{
            result: term(),
            mod: module(),
            fun: atom(),
            args: list(),
            fun_config: FunConfig.t(),
            request: Request.t(),
            rpc_timeout: pos_integer(),
            nodes: [node() | String.t()],
            retry_config: term()
          }

    defstruct result: nil,
              mod: nil,
              fun: nil,
              args: [],
              fun_config: nil,
              request: nil,
              rpc_timeout: 5000,
              nodes: [],
              retry_config: nil
  end

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
      # Use get_fast/2 for the hot path — it skips version resolution and uses
      # :ets.match_object for efficient pattern matching. Only fall back to
      # get_latest/2 when the request specifies an explicit version.
      result =
        case resolve_config(request) do
          {:ok, fun_config} ->
            execute_with_config!(request, fun_config)

          {:error, :not_found} ->
            version = request.version || "latest"

            Logger.warning(
              "[Executor] unsupported function: #{request.request_type}, version: #{version}, request_id: #{request.request_id}"
            )

            Response.error_response(
              request.request_id,
              "unsupported function: #{request.request_type} version #{version}"
            )

          {:error, :disabled} ->
            version = request.version || "latest"

            Logger.warning(
              "[Executor] disabled function: #{request.request_type}, version: #{version}, request_id: #{request.request_id}"
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
      "[Executor] executing request_id: #{request.request_id}, response_type: #{fun_config.response_type}"
    )

    # Run before_execute hook
    case Hooks.run_before(fun_config.before_execute, request, fun_config) do
      {:ok, new_request, new_fun_config} ->
        do_execute_with_config!(new_request, new_fun_config)

      {:error, reason} ->
        Logger.warning(
          "[Executor] before_execute hook aborted, request_id: #{request.request_id}, reason: #{inspect(reason)}"
        )

        response =
          Response.error_response(request.request_id, "hook rejected: #{inspect(reason)}")

        Hooks.run_after(fun_config.after_execute, request, fun_config, response)
        response
    end
  end

  defp do_execute_with_config!(request, fun_config) do
    case RateLimiter.check_rate_limit(request) do
      :ok ->
        try do
          Permission.check_permission!(request, fun_config)

          result =
            case fun_config.response_type do
              :sync ->
                do_call(request, fun_config)

              :async ->
                async_call(request, fun_config)

              :none ->
                async_call(request, fun_config)

              :stream ->
                stream_call(request, fun_config)

              other ->
                Logger.error(
                  "[Executor] unsupported response_type: #{inspect(other)}, request_id: #{request.request_id}"
                )

                Response.error_response(
                  request.request_id,
                  "unsupported response type: #{inspect(other)}"
                )
            end

          Hooks.run_after(fun_config.after_execute, request, fun_config, result)
          result
        rescue
          _e in PhoenixGenApi.Permission.PermissionDenied ->
            error_response = Response.error_response(request.request_id, "Permission denied")
            Hooks.run_after(fun_config.after_execute, request, fun_config, error_response)
            error_response
        end

      error ->
        result = handle_rate_limit_error(error, request, fun_config)
        Hooks.run_after(fun_config.after_execute, request, fun_config, result)
        result
    end
  end

  defp handle_rate_limit_error({:error, :rate_limited, details}, request, _fun_config) do
    retry_after_ms = Map.get(details, :retry_after_ms, 0)

    Response.error_response(
      request.request_id,
      "Rate limit exceeded. Please retry after #{div(retry_after_ms, 1000)} seconds.",
      true
    )
    |> Map.put(:can_retry, true)
  end

  defp handle_rate_limit_error({:error, :rate_limiter_error, error_details}, request, _fun_config) do
    Logger.error(
      "[Executor] rate_limiter_error: #{inspect(error_details)}, request_id: #{request.request_id}, rejecting request (fail-closed)"
    )

    Response.error_response(request.request_id, "Rate limit service unavailable", true)
  end

  defp handle_rate_limit_error({:error, :permission_denied}, request, _fun_config) do
    Logger.warning("[Executor] permission_denied for request_id: #{request.request_id}")

    Response.error_response(request.request_id, "Permission denied")
  end

  defp handle_rate_limit_error(error, request, _fun_config) do
    Logger.error(
      "[Executor] unexpected rate_limit error: #{inspect(error)}, request_id: #{request.request_id}, rejecting request (fail-closed)"
    )

    Response.error_response(request.request_id, "Rate limit service unavailable", true)
  end

  def sync_call(request, fun_config) do
    try do
      do_call(request, fun_config)
    rescue
      e ->
        Logger.error(
          "[Executor] sync_call rescued error: #{Exception.message(e)}, request_id: #{request.request_id}"
        )

        Response.error_response(request.request_id, get_error_message(e))
    catch
      :exit, reason ->
        Logger.error(
          "[Executor] sync_call exit: #{inspect(reason)}, request_id: #{request.request_id}"
        )

        Response.error_response(request.request_id, get_error_message(reason))

      :throw, reason ->
        Logger.error(
          "[Executor] sync_call throw: #{inspect(reason)}, request_id: #{request.request_id}"
        )

        Response.error_response(request.request_id, get_error_message(reason))

      kind, reason ->
        Logger.error(
          "[Executor] sync_call caught #{inspect(kind)}: #{inspect(reason)}, request_id: #{request.request_id}"
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
      if FunConfig.local_service?(fun_config) do
        execute_local_with_retry(mod, fun, final_args, fun_config.timeout, retry_config)
      else
        execute_remote_with_retry(mod, fun, final_args, fun_config, request, retry_config)
      end

    handle_call_result(result, request.request_id)
  end

  defp execute_local(mod, fun, args, timeout) do
    # Validate MFA before calling to prevent arbitrary code execution
    if function_exported?(mod, fun, length(args)) do
      task = Task.async(fn -> apply(mod, fun, args) end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, "local execution timed out after #{timeout}ms"}
        {:exit, reason} -> {:error, "local execution failed: #{inspect(reason)}"}
      end
    else
      Logger.error("[Executor] MFA not exported: #{inspect(mod)}.#{inspect(fun)}/#{length(args)}")

      {:error, :function_not_found}
    end
  end

  # Retry helpers for local execution

  defp execute_local_with_retry(mod, fun, args, timeout, retry_config) do
    result = execute_local(mod, fun, args, timeout)
    apply_local_retry(result, mod, fun, args, timeout, retry_config)
  end

  defp apply_local_retry(result, mod, fun, args, timeout, retry_config) do
    if retryable_error?(result) and has_retry_remaining?(retry_config) do
      {mode, n} = retry_config

      backoff_ms = NodeSelector.calculate_backoff(n)

      Logger.info(
        "[Executor] local retry mode: #{mode}, remaining: #{n}, backoff: #{backoff_ms}ms, mfa: #{inspect(mod)}.#{inspect(fun)}/#{length(args)}"
      )

      Process.sleep(backoff_ms)

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n, backoff_ms: backoff_ms},
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
    case NodeSelector.get_nodes(fun_config, request) do
      {:ok, nodes} ->
        rpc_timeout = get_rpc_timeout(fun_config)

        state = %RetryState{
          mod: mod,
          fun: fun,
          args: args,
          fun_config: fun_config,
          request: request,
          rpc_timeout: rpc_timeout,
          nodes: nodes,
          retry_config: retry_config
        }

        result =
          execute_remote_with_fallback(
            nodes,
            mod,
            fun,
            args,
            rpc_timeout,
            request.request_id,
            nil
          )

        apply_remote_retry(%{state | result: result})

      {:error, reason} ->
        Logger.error(
          "[Executor] node_selection failed: #{inspect(reason)}, request_id: #{request.request_id}"
        )

        {:error, "node selection failed: #{inspect(reason)}"}
    end
  end

  defp apply_remote_retry(state = %RetryState{retry_config: {:same_node, n}}) when n > 0 do
    if retryable_error?(state.result) do
      backoff_ms = NodeSelector.calculate_backoff(n)

      Logger.info(
        "[Executor] remote retry mode: same_node, remaining: #{n}, backoff: #{backoff_ms}ms, nodes: #{inspect(state.nodes)}, mfa: #{inspect(state.mod)}.#{inspect(state.fun)}/#{length(state.args)}, request_id: #{state.request.request_id}"
      )

      Process.sleep(backoff_ms)

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n, backoff_ms: backoff_ms},
        %{mode: :same_node, type: :remote, nodes: state.nodes}
      )

      # Retry on the same nodes that were originally selected
      new_result =
        execute_remote_with_fallback(
          state.nodes,
          state.mod,
          state.fun,
          state.args,
          state.rpc_timeout,
          state.request.request_id,
          nil
        )

      apply_remote_retry(%{state | result: new_result, retry_config: {:same_node, n - 1}})
    else
      state.result
    end
  end

  defp apply_remote_retry(state = %RetryState{retry_config: {:all_nodes, n}}) when n > 0 do
    if retryable_error?(state.result) do
      # Retry on ALL available nodes
      all_nodes =
        case NodeSelector.resolve_nodes_list(state.fun_config) do
          {:ok, nodes} -> nodes
          {:error, _} -> []
        end

      backoff_ms = NodeSelector.calculate_backoff(n)

      Logger.info(
        "[Executor] remote retry mode: all_nodes, remaining: #{n}, backoff: #{backoff_ms}ms, nodes: #{inspect(all_nodes)}, mfa: #{inspect(state.mod)}.#{inspect(state.fun)}/#{length(state.args)}, request_id: #{state.request.request_id}"
      )

      Process.sleep(backoff_ms)

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n, backoff_ms: backoff_ms},
        %{mode: :all_nodes, type: :remote, nodes: all_nodes}
      )

      new_result =
        execute_remote_with_fallback(
          all_nodes,
          state.mod,
          state.fun,
          state.args,
          state.rpc_timeout,
          state.request.request_id,
          nil
        )

      apply_remote_retry(%{
        state
        | result: new_result,
          nodes: all_nodes,
          retry_config: {:all_nodes, n - 1}
      })
    else
      state.result
    end
  end

  defp apply_remote_retry(state = %RetryState{}), do: state.result

  defp retryable_error?({:error, _}), do: true
  defp retryable_error?({:error, _, _}), do: true
  defp retryable_error?(_), do: false

  defp has_retry_remaining?({:same_node, n}) when n > 0, do: true
  defp has_retry_remaining?({:all_nodes, n}) when n > 0, do: true
  defp has_retry_remaining?(_), do: false

  defp execute_remote_with_fallback([], _mod, _fun, _args, _timeout, _request_id, last_error) do
    Logger.error("[Executor] no nodes available for remote execution")
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
          "[Executor] RPC timeout on node: #{inspect(node)}, request_id: #{request_id}, trying fallback"
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

      # Handle {:EXIT, _} to avoid leaking internal node details to the client
      {:badrpc, {:EXIT, reason}} ->
        Logger.warning(
          "[Executor] RPC exit on node: #{inspect(node)}, reason: #{inspect(reason)}, request_id: #{request_id}, trying fallback"
        )

        execute_remote_with_fallback(
          remaining_nodes,
          mod,
          fun,
          args,
          timeout,
          request_id,
          {:error, :rpc_exit}
        )

      {:badrpc, reason} ->
        Logger.warning(
          "[Executor] RPC failed on node: #{inspect(node)}, reason: #{inspect(reason)}, request_id: #{request_id}, trying fallback"
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
      Logger.error(
        "[Executor] failed to build info_args: #{Exception.message(e)}, request_id: #{request.request_id}"
      )

      []
  end

  defp handle_call_result(result = {:error, _reason}, request_id) do
    Response.error_response(request_id, get_error_message(result))
  end

  defp handle_call_result({:ok, result}, request_id) do
    Response.sync_response(request_id, result)
  end

  # Only treat plain values (non-tuples or non-error tuples) as success.
  defp handle_call_result(result, request_id) when not is_tuple(result) do
    Logger.warning(
      "[Executor] handle_call_result non-tuple result: #{inspect(result)}, request_id: #{request_id}"
    )

    Response.sync_response(request_id, result)
  end

  defp handle_call_result(result, request_id) do
    Logger.error(
      "[Executor] handle_call_result unexpected result: #{inspect(result)}, request_id: #{request_id}"
    )

    Response.error_response(request_id, "Unexpected execution result")
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
            "[Executor] async_call task failed: #{inspect(kind)}: #{inspect(reason)}, request_id: #{request.request_id}"
          )

          if Process.alive?(receiver) do
            error_response = Response.error_response(request.request_id, "Async execution failed")
            send(receiver, {:async_call, error_response})
          end
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
        Logger.warning(
          "[Executor] async_call worker_pool queue_full, request_id: #{request.request_id}"
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
            if Process.alive?(receiver) do
              send(receiver, {:stream_started, request_id, pid})
            end

            # Wait for stream to complete with timeout
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
            after
              fun_config.timeout ->
                Logger.warning(
                  "[Executor] stream_call timeout after #{fun_config.timeout}ms, request_id: #{request_id}"
                )

                GenServer.stop(pid, :timeout)
            end

          {:error, reason} ->
            Logger.error(
              "[Executor] stream_call start_link failed: #{inspect(reason)}, request_id: #{request_id}"
            )

            if Process.alive?(receiver) do
              send(
                receiver,
                {:stream_response, Response.error_response(request_id, "Failed to start stream")}
              )
            end
        end
      catch
        kind, reason ->
          Logger.error(
            "[Executor] stream_call task failed: #{inspect(kind)}: #{inspect(reason)}, request_id: #{request_id}"
          )

          if Process.alive?(receiver) do
            send(
              receiver,
              {:stream_response, Response.error_response(request_id, "Stream execution failed")}
            )
          end
      end
    end

    case PhoenixGenApi.WorkerPool.execute_async(:async_pool, task) do
      :ok ->
        Response.stream_response(request_id, :init)

      {:error, :queue_full} ->
        Logger.warning("[Executor] stream_call worker_pool queue_full, request_id: #{request_id}")

        Response.error_response(request_id, "Service temporarily unavailable", true)
    end
  end

  # Resolves the function config for a request.
  # Uses get_fast/2 (hot path) when no explicit version is requested — this
  # skips version resolution and uses :ets.match_object for fast lookup.
  # Falls back to get_latest/2 when an explicit version is specified.
  defp resolve_config(request) do
    if request.version do
      ConfigDb.get(request.service, request.request_type, request.version)
    else
      ConfigDb.get_fast(request.service, request.request_type)
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
