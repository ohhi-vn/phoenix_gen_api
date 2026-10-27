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

  When all retry attempts are exhausted, the executor returns a
  `%Response{success: false, error: "all retry attempts exhausted", can_retry: false}`
  to the client. A telemetry event at
  `[:phoenix_gen_api, :executor, :retry, :exhausted]` is also emitted with
  metadata containing the `request_id`, retry `mode`, and the last error result.
  """

  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Errors.Classify
  alias PhoenixGenApi.Hooks
  alias PhoenixGenApi.LogContext
  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Permission.PermissionDenied
  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}

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
  @task_supervisor PhoenixGenApi.TaskSupervisor

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
    LogContext.with_context(LogContext.request_context(request), fn ->
      do_execute!(request)
    end)
  end

  defp do_execute!(request = %Request{}) do
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

    # Request tracing — cheap no-op unless the request_type/user_id is traced
    trace_ctx = PhoenixGenApi.Tracer.begin_trace(request)

    try do
      # Use get_fast/2 for the hot path — it skips version resolution and uses
      # :ets.match_object for efficient pattern matching. Only fall back to
      # get_latest/2 when the request specifies an explicit version.
      result =
        case resolve_config(request) do
          {:ok, fun_config} ->
            PhoenixGenApi.Tracer.trace_event("config_lookup", %{
              "status" => "ok",
              "version" => fun_config.version || "latest"
            })

            execute_with_config!(request, fun_config)

          {:error, :unavailable} ->
            Logger.error(
              LogContext.line(
                "Executor",
                :config_cache_unavailable,
                "configuration cache unavailable",
                LogContext.current(failure_class: :unavailable, node: node())
              )
            )

            :telemetry.execute(
              [:phoenix_gen_api, :executor, :request, :exception],
              %{duration_us: System.monotonic_time(:microsecond) - start_time},
              %{
                request_id: request.request_id,
                request_type: request.request_type,
                service: request.service,
                user_id: request.user_id,
                kind: :error,
                reason: :config_cache_unavailable,
                failure_class: :unavailable,
                stacktrace: nil
              }
            )

            Response.error_response(
              request.request_id,
              "Service temporarily unavailable",
              true
            )

          {:error, :not_found} ->
            version = request.version || "latest"

            PhoenixGenApi.Tracer.trace_event("config_lookup", %{
              "status" => "not_found",
              "version" => version
            })

            Logger.warning(
              LogContext.line(
                "Executor",
                :unsupported_function,
                "unsupported function",
                LogContext.current(version: version, node: node())
              )
            )

            Response.error_response(
              request.request_id,
              "unsupported function: #{request.request_type} version #{version}"
            )

          {:error, :disabled} ->
            version = request.version || "latest"

            PhoenixGenApi.Tracer.trace_event("config_lookup", %{
              "status" => "disabled",
              "version" => version
            })

            Logger.warning(
              LogContext.line(
                "Executor",
                :disabled_function,
                "disabled function",
                LogContext.current(version: version, node: node())
              )
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

      PhoenixGenApi.Tracer.trace_result(request, result, duration)

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
            failure_class: Classify.classify(:error, e),
            stacktrace: __STACKTRACE__
          }
        )

        PhoenixGenApi.Tracer.trace_result(
          request,
          %Response{request_id: request.request_id, error: Exception.message(e), success: false},
          duration
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time(:microsecond) - start_time

        :telemetry.execute(
          [:phoenix_gen_api, :executor, :request, :exception],
          %{duration_us: duration},
          %{
            request_id: request.request_id,
            request_type: request.request_type,
            service: request.service,
            user_id: request.user_id,
            kind: kind,
            reason: inspect(reason),
            failure_class: Classify.classify(kind, reason),
            stacktrace: __STACKTRACE__
          }
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      PhoenixGenApi.Tracer.end_trace(trace_ctx)
    end
  end

  def execute_with_config!(request = %Request{}, fun_config = %FunConfig{}) do
    Logger.debug(fn ->
      LogContext.line(
        "Executor",
        :executing_request,
        "executing request",
        LogContext.current(
          response_type: fun_config.response_type,
          version: LogContext.value(fun_config.version),
          node: node()
        )
      )
    end)

    # Run before_execute hook
    case Hooks.run_before(fun_config.before_execute, request, fun_config) do
      {:ok, new_request, new_fun_config} ->
        PhoenixGenApi.Tracer.trace_event("hook_before", %{"status" => "ok"})
        do_execute_with_config!(new_request, new_fun_config)

      {:error, reason} ->
        PhoenixGenApi.Tracer.trace_event("hook_before", %{
          "status" => "error",
          "reason" => inspect(reason)
        })

        Logger.warning(
          LogContext.line(
            "Executor",
            :before_hook_aborted,
            "before_execute hook aborted",
            LogContext.current(reason: reason)
          )
        )

        response =
          Response.error_response(request.request_id, "hook rejected: #{inspect(reason)}")

        run_after_hook(request, fun_config, response)
    end
  end

  # Runs the configured after_execute hook. A failed hook keeps the original
  # response, but the failure is distinct from a hook that returned it unchanged.
  defp run_after_hook(request, fun_config, response) do
    case Hooks.run_after_tagged(fun_config.after_execute, request, fun_config, response) do
      {:ok, new_response} ->
        PhoenixGenApi.Tracer.trace_event("hook_after", %{"status" => "ok"})
        new_response

      {:error, %{kind: kind, reason: reason}} ->
        PhoenixGenApi.Tracer.trace_event("hook_after", %{
          "status" => "error",
          "kind" => inspect(kind),
          "reason" => inspect(reason)
        })

        response
    end
  end

  defp do_execute_with_config!(request, fun_config) do
    # Security: Permission check runs FIRST (cheap, no ETS writes).
    # Unauthenticated requests are rejected before consuming rate limit resources.
    # Execution order: Permission check → Rate limit check → Argument validation → Execution
    if needs_remote_permission_check?(fun_config) do
      # Pre-resolve the target node so permission check and execution use the same node
      case NodeSelector.get_node(fun_config, request) do
        {:ok, node} ->
          Permission.check_permission_remote!(request, fun_config, node)

        {:error, reason} ->
          Logger.error(
            LogContext.line(
              "Executor",
              :permission_node_selection_failed,
              "node selection failed for remote permission callback",
              LogContext.current(reason: reason, node: :none)
            )
          )

          raise PermissionDenied.exception(
                  user_id: request.user_id,
                  request_id: request.request_id,
                  request_type: request.request_type,
                  permission_mode: {:callback, fun_config.permission_callback}
                )
      end
    else
      Permission.check_permission!(request, fun_config)
    end

    PhoenixGenApi.Tracer.trace_permission(request, fun_config, :allowed)
  rescue
    _e in PermissionDenied ->
      PhoenixGenApi.Tracer.trace_permission(request, fun_config, :denied)
      error_response = Response.error_response(request.request_id, "Permission denied")
      run_after_hook(request, fun_config, error_response)
      error_response
  else
    _ ->
      case RateLimiter.check_rate_limit(request) do
        :ok ->
          PhoenixGenApi.Tracer.trace_event("rate_limit", %{"status" => "allowed"})

          result = execute_request(request, fun_config)
          run_after_hook(request, fun_config, result)

        error ->
          result = handle_rate_limit_error(error, request, fun_config)
          run_after_hook(request, fun_config, result)
      end
  end

  # Determines if the permission callback must run on a remote target node.
  # Returns true when a custom permission_callback is set AND the service
  # is not local (the callback module only exists on remote nodes).
  defp needs_remote_permission_check?(%FunConfig{permission_callback: nil}), do: false

  defp needs_remote_permission_check?(fun_config = %FunConfig{permission_callback: {_, _, _}}) do
    not FunConfig.local_service?(fun_config)
  end

  defp execute_request(request, fun_config) do
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
          LogContext.line(
            "Executor",
            :unsupported_response_type,
            "unsupported response_type",
            LogContext.current(response_type: other)
          )
        )

        Response.error_response(
          request.request_id,
          "unsupported response type: #{inspect(other)}"
        )
    end
  end

  defp handle_rate_limit_error({:error, :rate_limited, details}, request, _fun_config) do
    retry_after_ms = Map.get(details, :retry_after_ms, 0)

    PhoenixGenApi.Tracer.trace_event("rate_limit", %{
      "status" => "limited",
      "retry_after_ms" => retry_after_ms
    })

    Response.error_response(
      request.request_id,
      "Rate limit exceeded. Please retry after #{div(retry_after_ms, 1000)} seconds.",
      true
    )
    |> Map.put(:can_retry, true)
  end

  defp handle_rate_limit_error({:error, :rate_limiter_error, error_details}, request, _fun_config) do
    PhoenixGenApi.Tracer.trace_event("rate_limit", %{
      "status" => "error",
      "error" => inspect(error_details)
    })

    Logger.error(
      LogContext.line(
        "Executor",
        :rate_limiter_error,
        "rate_limiter_error, rejecting request (fail-closed)",
        LogContext.current(error: error_details)
      )
    )

    Response.error_response(request.request_id, "Rate limit service unavailable", true)
  end

  defp handle_rate_limit_error(error, request, _fun_config) do
    PhoenixGenApi.Tracer.trace_event("rate_limit", %{
      "status" => "error",
      "error" => inspect(error)
    })

    Logger.error(
      LogContext.line(
        "Executor",
        :unexpected_rate_limit_error,
        "unexpected rate_limit error, rejecting request (fail-closed)",
        LogContext.current(error: error)
      )
    )

    Response.error_response(request.request_id, "Rate limit service unavailable", true)
  end

  def sync_call(request, fun_config) do
    do_call(request, fun_config)
  rescue
    e ->
      PhoenixGenApi.Tracer.trace_event("error", %{
        "kind" => "error",
        "error" => Exception.message(e)
      })

      Logger.error(
        LogContext.line(
          "Executor",
          :sync_call_error,
          "sync_call rescued error",
          LogContext.current(error: Exception.message(e), kind: :error)
        )
      )

      Response.error_response(request.request_id, get_error_message(e))
  catch
    :exit, reason ->
      PhoenixGenApi.Tracer.trace_event("error", %{"kind" => "exit", "error" => inspect(reason)})

      Logger.error(
        LogContext.line(
          "Executor",
          :sync_call_exit,
          "sync_call exit",
          LogContext.current(reason: reason)
        )
      )

      Response.error_response(request.request_id, get_error_message(reason))

    :throw, reason ->
      PhoenixGenApi.Tracer.trace_event("error", %{"kind" => "throw", "error" => inspect(reason)})

      Logger.error(
        LogContext.line(
          "Executor",
          :sync_call_throw,
          "sync_call throw",
          LogContext.current(reason: reason)
        )
      )

      Response.error_response(request.request_id, get_error_message(reason))

    kind, reason ->
      PhoenixGenApi.Tracer.trace_event("error", %{
        "kind" => inspect(kind),
        "error" => inspect(reason)
      })

      Logger.error(
        LogContext.line(
          "Executor",
          :sync_call_caught,
          "sync_call caught",
          LogContext.current(kind: kind, reason: reason)
        )
      )

      Response.error_response(request.request_id, get_error_message(reason))
  end

  defp do_call(request, fun_config) do
    args =
      try do
        ArgumentHandler.convert_args!(fun_config, request)
      rescue
        e ->
          PhoenixGenApi.Tracer.trace_event("arguments", %{
            "status" => "error",
            "error" => Exception.message(e)
          })

          reraise e, __STACKTRACE__
      end

    if PhoenixGenApi.Tracer.traced?() do
      PhoenixGenApi.Tracer.trace_event("arguments", %{"status" => "ok", "count" => length(args)})
    end

    {mod, fun, predefined_args} = fun_config.mfa

    final_args = predefined_args ++ args ++ info_args(request, fun_config)
    retry_config = FunConfig.normalize_retry(fun_config.retry)

    result =
      if FunConfig.local_service?(fun_config) do
        if PhoenixGenApi.Tracer.traced?() do
          PhoenixGenApi.Tracer.trace_event("execution", %{
            "mode" => "local",
            "mfa" => "#{inspect(mod)}.#{fun}/#{length(final_args)}"
          })
        end

        execute_local_with_retry(
          mod,
          fun,
          final_args,
          fun_config.timeout,
          retry_config,
          request.request_id
        )
      else
        if PhoenixGenApi.Tracer.traced?() do
          PhoenixGenApi.Tracer.trace_event("execution", %{
            "mode" => "remote",
            "mfa" => "#{inspect(mod)}.#{fun}/#{length(final_args)}"
          })
        end

        execute_remote_with_retry(mod, fun, final_args, fun_config, request, retry_config)
      end

    result = apply_result_encoder(fun_config, result)

    handle_call_result(result, request.request_id)
  end

  # Applies the FunConfig's result_encoder to a successful mfa result, if
  # configured. Only `{:ok, data}` results are encoded — the encoder receives
  # only `data` as its first argument followed by the tuple's args, and its
  # return value is re-wrapped as `{:ok, encoded}`. All other result shapes
  # (including `{:error, reason}`) pass through untouched. Encoder failures are
  # logged and returned as an error response instead of crashing the channel.
  defp apply_result_encoder(%FunConfig{result_encoder: nil}, result), do: result

  defp apply_result_encoder(fun_config, {:ok, data}) do
    case encode_result(fun_config, data) do
      {:error, _} = error -> error
      {:ok, _} = result -> result
      encoded -> {:ok, encoded}
    end
  end

  defp apply_result_encoder(_fun_config, result), do: result

  defp encode_result(%FunConfig{result_encoder: {mod, fun, args}}, data) do
    case PhoenixGenApi.Security.validate_mfa({mod, fun, args}) do
      :ok ->
        try do
          apply(mod, fun, [data | args])
        rescue
          e ->
            Logger.error(
              LogContext.line(
                "Executor",
                :result_encoder_failed,
                "result_encoder failed",
                LogContext.current(
                  encoder: "#{inspect(mod)}.#{fun}",
                  reason: Exception.message(e)
                )
              )
            )

            {:error, "result encoding failed: #{Exception.message(e)}"}
        catch
          kind, value ->
            Logger.error(
              LogContext.line(
                "Executor",
                :result_encoder_caught,
                "result_encoder caught",
                LogContext.current(
                  encoder: "#{inspect(mod)}.#{fun}",
                  kind: kind,
                  value: value
                )
              )
            )

            {:error, "result encoding failed: #{inspect({kind, value})}"}
        end

      {:error, {:mfa_not_allowed, _}} ->
        Logger.error(
          LogContext.line(
            "Executor",
            :result_encoder_mfa_not_allowed,
            "result_encoder MFA not allowed",
            LogContext.current(encoder: "#{inspect(mod)}.#{fun}")
          )
        )

        {:error, "result encoder mfa not allowed"}
    end
  end

  defp execute_local(mod, fun, args, timeout) do
    # Validate MFA before calling to prevent arbitrary code execution
    with :ok <- PhoenixGenApi.Security.validate_mfa({mod, fun, args}),
         true <- function_exported?(mod, fun, length(args)) do
      case run_isolated(fn -> apply(mod, fun, args) end, timeout) do
        {:ok, result} -> result
        {:error, :timeout} -> {:error, "local execution timed out after #{inspect(timeout)}ms"}
        {:exit, reason} -> {:error, "local execution failed: #{inspect(reason)}"}
      end
    else
      {:error, {:mfa_not_allowed, _}} = error ->
        Logger.error(
          LogContext.line(
            "Executor",
            :local_mfa_not_allowed,
            "local MFA not allowed",
            LogContext.current(mfa: "#{inspect(mod)}.#{fun}/#{length(args)}")
          )
        )

        error

      false ->
        Logger.error(
          LogContext.line(
            "Executor",
            :mfa_not_exported,
            "MFA not exported",
            LogContext.current(mfa: "#{inspect(mod)}.#{fun}/#{length(args)}")
          )
        )

        {:error, :function_not_found}
    end
  end

  # Runs `fun` in an isolated process so a raise, throw, or exit in endpoint code
  # cannot take down the caller. Prefers the supervised task supervisor; falls
  # back to a monitored process when it is not running.
  defp run_isolated(fun, timeout) when is_function(fun, 0) do
    # A monitored spawn is the fastest isolation primitive: no supervisor round
    # trip on the request path, and the caller is never linked to endpoint code.
    run_monitored(fun, timeout)
  end

  defp run_monitored(fun, timeout) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {tag, fun.()})
        exit(:normal)
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      normalize_timeout(timeout) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> {:error, :timeout}
        after
          5_000 -> {:error, :timeout}
        end
    end
  end

  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp normalize_timeout(_timeout), do: @default_rpc_timeout

  # Retry helpers for local execution
  defp execute_local_with_retry(mod, fun, args, timeout, retry_config, request_id) do
    result = execute_local(mod, fun, args, timeout)
    apply_local_retry(result, mod, fun, args, timeout, retry_config, request_id, retry_config)
  end

  defp apply_local_retry(
         result,
         mod,
         fun,
         args,
         timeout,
         retry_config,
         request_id,
         original_config
       ) do
    effective_config = original_config || retry_config

    if retryable_error?(result) and has_retry_remaining?(retry_config) do
      {mode, n} = retry_config

      backoff_ms = NodeSelector.calculate_backoff(n)

      PhoenixGenApi.Tracer.trace_event("retry", %{
        "attempt" => n,
        "mode" => mode,
        "backoff_ms" => backoff_ms,
        "type" => "local",
        "result" => inspect(result)
      })

      Logger.debug(fn ->
        LogContext.line(
          "Executor",
          :local_retry,
          "local retry",
          LogContext.current(
            mode: mode,
            remaining: n,
            backoff_ms: backoff_ms,
            mfa: "#{inspect(mod)}.#{fun}/#{length(args)}"
          )
        )
      end)

      Process.sleep(backoff_ms)

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n, backoff_ms: backoff_ms},
        %{mode: mode, type: :local}
      )

      new_result = execute_local(mod, fun, args, timeout)

      apply_local_retry(
        new_result,
        mod,
        fun,
        args,
        timeout,
        {mode, n - 1},
        request_id,
        effective_config
      )
    else
      if retryable_error?(result) and is_tuple(effective_config) do
        PhoenixGenApi.Tracer.trace_event("retry_exhausted", %{
          "mode" => inspect(effective_config),
          "type" => "local",
          "result" => inspect(result)
        })

        Logger.warning(
          LogContext.line(
            "Executor",
            :local_retry_exhausted,
            "all local retry attempts exhausted",
            LogContext.current(mode: effective_config)
          )
        )

        :telemetry.execute(
          [:phoenix_gen_api, :executor, :retry, :exhausted],
          %{},
          %{
            request_id: request_id,
            mode: effective_config,
            last_error: inspect(result)
          }
        )

        {:error, {:retry_exhausted, result}}
      else
        result
      end
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
          LogContext.line(
            "Executor",
            :node_selection_failed,
            "node_selection failed",
            LogContext.current(reason: reason, node: :none)
          )
        )

        {:error, "node selection failed: #{inspect(reason)}"}
    end
  end

  # Tail-recursive retry loop for remote execution.
  defp apply_remote_retry(state = %RetryState{retry_config: {:same_node, n}}) do
    if retryable_error?(state.result) and n > 0 do
      backoff_ms = NodeSelector.calculate_backoff(n)

      PhoenixGenApi.Tracer.trace_event("retry", %{
        "attempt" => n,
        "mode" => :same_node,
        "backoff_ms" => backoff_ms,
        "type" => "remote",
        "result" => inspect(state.result)
      })

      Logger.debug(fn ->
        LogContext.line(
          "Executor",
          :remote_retry,
          "remote retry",
          LogContext.current(
            mode: :same_node,
            remaining: n,
            backoff_ms: backoff_ms,
            nodes: state.nodes,
            mfa: "#{inspect(state.mod)}.#{state.fun}/#{length(state.args)}"
          )
        )
      end)

      Process.sleep(backoff_ms)

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry],
        %{attempt: n, backoff_ms: backoff_ms},
        %{mode: :same_node, type: :remote, nodes: state.nodes}
      )

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
      finalize_retry(state)
    end
  end

  defp apply_remote_retry(state = %RetryState{retry_config: {:all_nodes, n}}) do
    if retryable_error?(state.result) and n > 0 do
      case NodeSelector.resolve_nodes_list(state.fun_config) do
        {:ok, all_nodes} ->
          retry_all_nodes(state, all_nodes, n)

        {:error, reason} ->
          Logger.error(
            LogContext.line(
              "Executor",
              :retry_node_resolution_failed,
              "node resolution failed, stopping retries",
              LogContext.current(reason: reason)
            )
          )

          :telemetry.execute(
            [:phoenix_gen_api, :executor, :retry, :exhausted],
            %{},
            %{
              request_id: state.request.request_id,
              mode: state.retry_config,
              last_error: inspect({:node_resolution_failed, reason})
            }
          )

          {:error, {:retry_exhausted, {:node_resolution_failed, reason}}}
      end
    else
      finalize_retry(state)
    end
  end

  defp apply_remote_retry(state = %RetryState{}) do
    finalize_retry(state)
  end

  defp retry_all_nodes(state, all_nodes, n) do
    backoff_ms = NodeSelector.calculate_backoff(n)

    PhoenixGenApi.Tracer.trace_event("retry", %{
      "attempt" => n,
      "mode" => :all_nodes,
      "backoff_ms" => backoff_ms,
      "type" => "remote",
      "result" => inspect(state.result)
    })

    Logger.debug(fn ->
      LogContext.line(
        "Executor",
        :remote_retry,
        "remote retry",
        LogContext.current(
          mode: :all_nodes,
          remaining: n,
          backoff_ms: backoff_ms,
          nodes: all_nodes,
          mfa: "#{inspect(state.mod)}.#{state.fun}/#{length(state.args)}"
        )
      )
    end)

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
  end

  # Common retry finalization logic
  defp finalize_retry(%RetryState{result: result, retry_config: nil}), do: result

  defp finalize_retry(state = %RetryState{retry_config: config}) do
    if retryable_error?(state.result) do
      PhoenixGenApi.Tracer.trace_event("retry_exhausted", %{
        "mode" => inspect(config),
        "type" => "remote",
        "result" => inspect(state.result)
      })

      Logger.warning(
        LogContext.line(
          "Executor",
          :retry_exhausted,
          "all retry attempts exhausted",
          LogContext.current(mode: config)
        )
      )

      :telemetry.execute(
        [:phoenix_gen_api, :executor, :retry, :exhausted],
        %{},
        %{
          request_id: state.request.request_id,
          mode: config,
          last_error: inspect(state.result)
        }
      )

      {:error, {:retry_exhausted, state.result}}
    else
      state.result
    end
  end

  defp retryable_error?({:error, _}), do: true
  defp retryable_error?({:error, _, _}), do: true
  defp retryable_error?(_), do: false

  defp has_retry_remaining?({:same_node, n}) when n > 0, do: true
  defp has_retry_remaining?({:all_nodes, n}) when n > 0, do: true
  defp has_retry_remaining?(_), do: false

  defp execute_remote_with_fallback([], mod, fun, args, _timeout, _request_id, last_error) do
    Logger.error(
      LogContext.line(
        "Executor",
        :no_nodes_available,
        "no nodes available for remote execution",
        LogContext.current(node: :none, mfa: "#{inspect(mod)}.#{fun}/#{length(args)}")
      )
    )

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
        PhoenixGenApi.Tracer.trace_event("rpc_fallback", %{
          "node" => inspect(node),
          "reason" => "timeout"
        })

        Logger.warning(
          LogContext.line(
            "Executor",
            :rpc_timeout,
            "RPC timeout, trying fallback",
            LogContext.current(
              failed_node: node,
              node: node,
              reason: :timeout,
              mfa: "#{inspect(mod)}.#{fun}/#{length(args)}"
            )
          )
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
        PhoenixGenApi.Tracer.trace_event("rpc_fallback", %{
          "node" => inspect(node),
          "reason" => "exit",
          "error" => inspect(reason)
        })

        Logger.warning(
          LogContext.line(
            "Executor",
            :rpc_exit,
            "RPC exit, trying fallback",
            LogContext.current(
              failed_node: node,
              node: node,
              reason: reason,
              mfa: "#{inspect(mod)}.#{fun}/#{length(args)}"
            )
          )
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
        PhoenixGenApi.Tracer.trace_event("rpc_fallback", %{
          "node" => inspect(node),
          "reason" => inspect(reason)
        })

        Logger.warning(
          LogContext.line(
            "Executor",
            :rpc_failed,
            "RPC failed, trying fallback",
            LogContext.current(
              failed_node: node,
              node: node,
              reason: reason,
              mfa: "#{inspect(mod)}.#{fun}/#{length(args)}"
            )
          )
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
        LogContext.line(
          "Executor",
          :info_args_failed,
          "failed to build info_args",
          LogContext.current(error: Exception.message(e))
        )
      )

      []
  end

  defp handle_call_result({:error, {:retry_exhausted, _reason}}, request_id) do
    Response.error_response(request_id, "all retry attempts exhausted")
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
      LogContext.line(
        "Executor",
        :non_tuple_result,
        "handle_call_result non-tuple result",
        LogContext.current(result: LogContext.payload(result))
      )
    )

    Response.sync_response(request_id, result)
  end

  defp handle_call_result(result, request_id) do
    Logger.error(
      LogContext.line(
        "Executor",
        :unexpected_result,
        "handle_call_result unexpected result",
        LogContext.current(result: LogContext.payload(result))
      )
    )

    Response.error_response(request_id, "Unexpected execution result")
  end

  defp async_call(request, fun_config) do
    receiver = self()

    # Copy the caller's metadata (request context plus trace context) into the
    # worker process so its Logger output is attributable, then restore it
    # afterwards so a reused worker cannot leak the identity.
    metadata = Logger.metadata()

    task = fn ->
      LogContext.with_metadata(metadata, fn ->
        try do
          result = sync_call(request, fun_config)

          if fun_config.response_type != :none do
            send(receiver, {:async_call, result})
          end
        catch
          kind, reason ->
            Logger.error(
              LogContext.line(
                "Executor",
                :async_task_failed,
                "async_call task failed",
                LogContext.current(kind: kind, reason: reason)
              )
            )

            if Process.alive?(receiver) do
              error_response =
                Response.error_response(request.request_id, "Async execution failed")

              send(receiver, {:async_call, error_response})
            end
        end
      end)
    end

    case submit_to_pool(:async_pool, task) do
      :ok ->
        PhoenixGenApi.Tracer.trace_event("async", %{"status" => "queued"})

        if fun_config.response_type != :none do
          Response.async_response(request.request_id)
        else
          {:ok, :no_response}
        end

      {:error, :queue_full} ->
        PhoenixGenApi.Tracer.trace_event("async", %{"status" => "queue_full"})

        Logger.warning(
          LogContext.line(
            "Executor",
            :async_queue_full,
            "async_call worker_pool queue_full",
            LogContext.current(pool: :async_pool)
          )
        )

        Response.error_response(request.request_id, "Service temporarily unavailable", true)

      {:error, reason} ->
        reject_unavailable_pool(:async, :async_pool, reason, request.request_id)
    end
  end

  defp monitor_stream(pid, receiver, request) do
    spawn(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} ->
          handle_stream_down(request, reason, receiver)
      end
    end)

    :ok
  end

  defp handle_stream_down(request, reason, receiver) do
    normal? = reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason)

    if normal? do
      :telemetry.execute(
        [:phoenix_gen_api, :stream, :stop],
        %{duration_us: 0},
        %{
          request_id: request.request_id,
          request_type: request.request_type,
          service: request.service,
          chunks: 0,
          reason: :completed
        }
      )

      :ok
    else
      Logger.error(
        LogContext.line(
          "Executor",
          :stream_terminated,
          "stream_call terminated abnormally",
          LogContext.current(reason: reason, pool: :async_pool)
        )
      )

      :telemetry.execute(
        [:phoenix_gen_api, :stream, :exception],
        %{duration_us: 0},
        %{
          request_id: request.request_id,
          request_type: request.request_type,
          service: request.service,
          failure_class: Classify.classify(:exit, reason),
          reason: reason
        }
      )

      send_terminal_stream_error(receiver, request.request_id, "Stream terminated unexpectedly")
    end
  end

  defp send_terminal_stream_error(receiver, request_id, message) do
    if Process.alive?(receiver) do
      send(receiver, {:stream_response, Response.error_response(request_id, message)})
    end

    :ok
  end

  defp submit_to_pool(pool, task) do
    try do
      PhoenixGenApi.WorkerPool.execute_async(pool, task)
    catch
      :exit, reason -> {:error, {:unavailable, reason}}
    end
  end

  defp reject_unavailable_pool(kind, pool, reason, request_id) do
    failure_class = Classify.classify(:error, pool_failure_reason(reason))

    PhoenixGenApi.Tracer.trace_event("#{kind}", %{
      "status" => "unavailable",
      "reason" => inspect(reason)
    })

    Logger.warning(
      LogContext.line(
        "Executor",
        :pool_unavailable,
        "#{kind} pool unavailable",
        LogContext.current(pool: pool, kind: kind, reason: reason, failure_class: failure_class)
      )
    )

    Response.error_response(request_id, "Service temporarily unavailable", true)
  end

  defp pool_failure_reason({:unavailable, _reason}), do: :unavailable
  defp pool_failure_reason(reason), do: reason

  defp stream_call(request = %Request{}, fun_config = %FunConfig{}) do
    receiver = self()
    request_id = request.request_id

    # Copy the caller's metadata (request context plus trace context) into the
    # worker and stream processes so their Logger output is attributable.
    metadata = Logger.metadata()

    task = fn ->
      LogContext.with_metadata(metadata, fn ->
        try do
          case StreamCall.start_link(%{
                 request: request,
                 fun_config: fun_config,
                 receiver: receiver,
                 log_metadata: metadata
               }) do
            {:ok, pid} ->
              # Store the stream PID for potential cancellation
              if Process.alive?(receiver) do
                send(receiver, {:stream_started, request_id, pid})
              end

              # The stream process owns its lifetime and timeout, so the pool
              # slot is released as soon as ownership is handed off. A tiny
              # monitor process reports abnormal producer exits.
              monitor_stream(pid, receiver, request)

            {:error, reason} ->
              PhoenixGenApi.Tracer.trace_event("stream", %{
                "status" => "error",
                "error" => inspect(reason)
              })

              Logger.error(
                LogContext.line(
                  "Executor",
                  :stream_start_failed,
                  "stream_call start_link failed",
                  LogContext.current(pool: :stream_pool, reason: reason)
                )
              )

              if Process.alive?(receiver) do
                send(
                  receiver,
                  {:stream_response,
                   Response.error_response(request_id, "Failed to start stream")}
                )
              end
          end
        catch
          kind, reason ->
            Logger.error(
              LogContext.line(
                "Executor",
                :stream_task_failed,
                "stream_call task failed",
                LogContext.current(
                  pool: :stream_pool,
                  kind: kind,
                  reason: reason
                )
              )
            )

            if Process.alive?(receiver) do
              send(
                receiver,
                {:stream_response, Response.error_response(request_id, "Stream execution failed")}
              )
            end
        end
      end)
    end

    case submit_to_pool(:stream_pool, task) do
      :ok ->
        PhoenixGenApi.Tracer.trace_event("stream", %{"status" => "started"})
        Response.stream_response(request_id, :init)

      {:error, :queue_full} ->
        PhoenixGenApi.Tracer.trace_event("stream", %{"status" => "queue_full"})

        Logger.warning(
          LogContext.line(
            "Executor",
            :stream_queue_full,
            "stream_call worker_pool queue_full",
            LogContext.current(pool: :stream_pool)
          )
        )

        Response.error_response(request_id, "Service temporarily unavailable", true)

      {:error, reason} ->
        reject_unavailable_pool(:stream, :stream_pool, reason, request_id)
    end
  end

  # Resolves the function config for a request.
  # Uses get_fast/2 (hot path) when no explicit version is requested — this
  # skips version resolution and uses :ets.match_object for fast lookup.
  # Falls back to get/3 when an explicit version is specified.
  # The reserved sentinel "0.0.0" is treated as no version (uses get_fast).
  defp resolve_config(request) do
    allow_client_version? =
      Application.get_env(:phoenix_gen_api, :allow_client_version, true) != false

    client_version =
      if allow_client_version?, do: request.version, else: nil

    if client_version && client_version != "0.0.0" do
      ConfigDb.get(request.service, request.request_type, client_version)
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
    case run_isolated(fn -> execute!(request) end, timeout) do
      {:ok, result} ->
        result

      {:error, :timeout} ->
        Response.error_response(
          request.request_id,
          "Request timed out after #{inspect(timeout)}ms"
        )

      {:exit, reason} ->
        Response.error_response(request.request_id, "Request failed: #{inspect(reason)}")
    end
  end
end
