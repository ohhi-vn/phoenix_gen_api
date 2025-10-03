defmodule PhoenixGenApi.StreamCall do
  @moduledoc """
  A GenServer that manages a streaming function call.

  This process is responsible for executing a function that returns a stream of
  results, and sending those results back to the client in chunks.
  """

  use GenServer, restart: :temporary

  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}
  alias PhoenixGenApi.Executor

  require Logger

  def start_link(args = %{fun_config: %FunConfig{}, request: %Request{}, receiver: nil}) do
    start_link(Map.put(args, :receiver, self()))
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
          "PhoenixGenApi.StreamCall, stop, not found stream for request_id: #{inspect(request_id)}"
        )

        {:error, :not_found}

      pid when is_pid(pid) ->
        Logger.debug("PhoenixGenApi.StreamCall, stop, stream call pid: #{inspect(pid)}")
        stop(pid)
    end
  end

  ### GenServer Callbacks

  @impl true
  def init(args) do
    {:ok, args, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    result = Executor.execute_with_config!(state.request, state.fun_config)

    if Response.is_error?(result) do
      send(state.receiver, {:stream_response, result})
      {:stop, :normal, state}
    else
      send(
        state.receiver,
        {:stream_response, Response.stream_response(state.request.request_id, result)}
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    send_completion(state)
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
    send(
      state.receiver,
      {:stream_response, Response.stream_response(state.request.request_id, result, false)}
    )

    {:stop, :normal, state}
  end

  def handle_info({:error, error}, state) do
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

    {:stop, :normal, state}
  end

  def handle_info(:complete, state) do
    send_completion(state)
    {:stop, :normal, state}
  end

  def handle_info(unknown, state) do
    Logger.warning("PhoenixGenApi.StreamCall, received unknown message: #{inspect(unknown)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug(
      "PhoenixGenApi.StreamCall, terminating for request_id: #{state.request.request_id}, reason: #{inspect(reason)}"
    )

    :ok
  end

  defp send_completion(state) do
    send(
      state.receiver,
      {:stream_response, Response.stream_end_response(state.request.request_id)}
    )
  end
end
