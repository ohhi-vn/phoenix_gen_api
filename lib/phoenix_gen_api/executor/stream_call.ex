defmodule PhoenixGenApi.StreamCall do
  @moduledoc """
  A GenServer that manages a streaming function call.

  This process is responsible for executing a function that returns a stream of
  results, and sending those results back to the client in chunks via
  `{:stream_response, response}` messages.

  ## Lifecycle

  1. Started via `start_link/1` with a `%FunConfig{}`, `%Request{}`, and receiver pid.
  2. On init, immediately starts the stream via `handle_continue(:start_stream, ...)`.
  3. The MFA is called through `Executor.sync_call/2`.
  4. If the result is an error, sends a single error response and stops.
  5. If successful, sends the initial chunk and waits for further messages.
  6. The data generator sends `{:result, data}` for intermediate chunks,
     `{:last_result, data}` for the final chunk, or `{:error, reason}` on failure.
  7. On `:complete` or `:stop`, sends a stream-end response and stops.

  ## Messages to Data Generator

  The stream process expects these messages from the data generator:
  - `{:result, data}` — Intermediate chunk (sets `has_more: true`)
  - `{:last_result, data}` — Final chunk (sets `has_more: false`)
  - `{:error, reason}` — Error (sends error response)
  - `:complete` — Normal completion (sends stream-end response)

  ## Stopping

  Use `stop/1` with either the stream PID or the request_id to gracefully
  terminate a stream. This sends a completion response before stopping.
  """

  use GenServer, restart: :temporary

  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.LogContext
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}

  require Logger

  @default_stream_timeout 30_000

  def start_link(args = %{fun_config: %FunConfig{}, request: %Request{}, receiver: nil}) do
    receiver = self()
    start_link(Map.put(args, :receiver, receiver))
  end

  def start_link(args = %{fun_config: %FunConfig{}, request: %Request{}, receiver: receiver})
      when is_pid(receiver) do
    case GenServer.start_link(__MODULE__, args) do
      {:ok, pid} ->
        Process.put({:phoenix_gen_api, :stream_call_pid, args.request.request_id}, pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop(pid) when is_pid(pid) do
    GenServer.cast(pid, :stop)
  end

  def stop(request_id) when is_binary(request_id) do
    case Process.get({:phoenix_gen_api, :stream_call_pid, request_id}) do
      nil ->
        Logger.warning(
          LogContext.line(
            "StreamCall",
            :stream_stop_not_found,
            "stop stream not_found",
            LogContext.current(request_id: request_id)
          )
        )

        {:error, :not_found}

      pid when is_pid(pid) ->
        Logger.debug(fn ->
          LogContext.line(
            "StreamCall",
            :stream_stop_requested,
            "stop stream",
            LogContext.current(request_id: request_id, stream_pid: inspect(pid))
          )
        end)

        stop(pid)
    end
  end

  ### GenServer Callbacks

  @impl true
  def init(args = %{request: request}) do
    # The stream runs in its own process, so apply the originating metadata
    # (request context plus trace context) captured before the process spawn.
    if metadata = Map.get(args, :log_metadata) do
      Logger.metadata(metadata)
    end

    PhoenixGenApi.Tracer.apply_trace_metadata(request)
    timeout = stream_timeout(args.fun_config)
    {:ok, Map.put(args, :timeout, timeout), {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    result = Executor.sync_call(state.request, state.fun_config)

    if Response.error?(result) do
      send(state.receiver, {:stream_response, result})
      emit_stream_event(:stop, state, %{chunks: 0, reason: :error})
      {:stop, :normal, state}
    else
      send(
        state.receiver,
        {:stream_response, Response.stream_response(state.request.request_id, result)}
      )

      timer_ref = Process.send_after(self(), :stream_timeout, state.timeout)
      {:noreply, Map.put(state, :timer_ref, timer_ref)}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    cancel_timer(state)
    send_completion(state)
    emit_stream_event(:stop, state, %{chunks: 0, reason: :stopped})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:result, result}, state) do
    send(
      state.receiver,
      {:stream_response, Response.stream_response(state.request.request_id, result)}
    )

    {:noreply, state}
  end

  def handle_info({:last_result, result}, state) do
    cancel_timer(state)

    send(
      state.receiver,
      {:stream_response, Response.stream_response(state.request.request_id, result, false)}
    )

    emit_stream_event(:stop, state, %{chunks: 1, reason: :completed})
    {:stop, :normal, state}
  end

  def handle_info({:error, error}, state) do
    cancel_timer(state)

    error_message =
      if Application.get_env(:phoenix_gen_api, :detail_error, false) do
        "Internal Server Error: #{inspect(error)}"
      else
        "Internal Server Error"
      end

    send(
      state.receiver,
      {:stream_response, Response.error_response(state.request.request_id, error_message)}
    )

    emit_stream_event(:exception, state, %{
      failure_class: PhoenixGenApi.Errors.Classify.classify(:error, error),
      reason: error
    })

    {:stop, :normal, state}
  end

  def handle_info(:complete, state) do
    cancel_timer(state)
    send_completion(state)
    emit_stream_event(:stop, state, %{chunks: 0, reason: :completed})
    {:stop, :normal, state}
  end

  def handle_info(:stream_timeout, state) do
    Logger.warning(
      LogContext.line(
        "StreamCall",
        :stream_timeout,
        "stream timed out",
        LogContext.current(
          request_id: state.request.request_id,
          timeout_ms: state.timeout,
          stream_pid: inspect(self())
        )
      )
    )

    send(
      state.receiver,
      {:stream_response, Response.error_response(state.request.request_id, "Stream timed out")}
    )

    emit_stream_event(:exception, state, %{failure_class: :timeout, reason: :timeout})
    {:stop, :normal, %{state | timer_ref: nil}}
  end

  def handle_info(unknown, state) do
    Logger.warning(
      LogContext.line(
        "StreamCall",
        :unknown_message,
        "received unknown message",
        LogContext.current(
          request_id: state.request.request_id,
          message: inspect(unknown)
        )
      )
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    cancel_timer(state)

    Logger.debug(fn ->
      LogContext.line(
        "StreamCall",
        :terminating,
        "terminating",
        LogContext.current(
          request_id: state.request.request_id,
          stream_pid: inspect(self()),
          reason: inspect(reason)
        )
      )
    end)

    :ok
  end

  defp send_completion(state) do
    send(
      state.receiver,
      {:stream_response, Response.stream_end_response(state.request.request_id)}
    )
  end

  defp stream_timeout(%FunConfig{timeout: timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp stream_timeout(_fun_config), do: @default_stream_timeout

  defp cancel_timer(state) do
    case Map.get(state, :timer_ref) do
      nil -> :ok
      ref -> Process.cancel_timer(ref, async: true, info: false)
    end
  end

  defp emit_stream_event(event, state, extra) do
    :telemetry.execute(
      [:phoenix_gen_api, :stream, event],
      %{duration_us: 0},
      Map.merge(
        %{
          request_id: state.request.request_id,
          request_type: state.request.request_type,
          service: state.request.service
        },
        extra
      )
    )
  end
end
