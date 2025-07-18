defmodule PhoenixGenApi.StreamCall do
  @moduledoc """
  Module helps to handle stream call.
  """
  use GenServer, restart: :temporary

  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}
  alias PhoenixGenApi.Executor

  require Logger

  def start_link(args = %{fun_config: %FunConfig{}, request: %Request{}})do
    args =
      if Map.has_key?(args, :receiver) do
        args
      else
        Map.put(args, :receiver, self())
      end

    Logger.debug("PhoenixGenApi.StreamCall, start_link, args: #{inspect args}, parent pid: #{inspect self()}")

    GenServer.start_link(__MODULE__, args)
  end

  def send_data(pid, data) do
    GenServer.cast(pid, {:stream_send, data})
  end

  def send_last_data(pid, data) do
    GenServer.cast(pid, {:last_result, data})
  end

  # When stop by manual generator process cannot get notification
  # TO-D: Implement callback for easy to work with stream call.
  def stop(request_id) when is_binary(request_id) do
    case Process.get({:phoenix_gen_api, :stream_call_pid, request_id}) do
      nil ->
        Logger.info("PhoenixGenApi.StreamCall, stop, not found stream for request_id: #{inspect request_id}")
        :ok
      pid when is_pid(pid) ->
        Logger.debug("PhoenixGenApi.StreamCall, stop, stream call pid: #{inspect pid}")
        stop(pid)
    end
  end
  def stop(pid) when is_pid(pid) do
    GenServer.cast(pid, :stream_stop)
  end

  ## GenServer callbacks

  @impl true
  def init(args) do
    Logger.debug("PhoenixGenApi.StreamCall, init, args: #{inspect args}, pid: #{inspect self()}")

    {:ok, args, {:continue, :start_call}}
  end

  @impl true
  def handle_continue(:start_call, state) do
    result = Executor.call(state.request, state.fun_config)

    result = %{result | has_more: true}
    Logger.debug("PhoenixGenApi.StreamCall, handle_continue, result: #{inspect result}")

    send(state.receiver, {:stream_response, result})

    if Response.is_error?(result) do
      Logger.error("PhoenixGenApi.StreamCall, handle_continue, rpc failed, error: #{inspect result}")
      done(state)

      {:stop, :error, state}
    else

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:stream_stop, state) do
    Logger.debug("PhoenixGenApi.StreamCall, stream_call, handle_cast, stop")

    done(state)

    {:stop, :normal, state}
  end

  def handle_cast({:stream_send, result}, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_cast, result: #{inspect result}")

    result = Response.stream_response(state.request.request_id, result)
    send(state.receiver, {:stream_response, result})

    {:noreply, state}
  end


  @impl true
  def handle_info({:result, result}, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, result: #{inspect result}")

    result = Response.stream_response(state.request.request_id, result)
    send(state.receiver, {:stream_response, result})

    {:noreply, state}
  end

  def handle_info({:last_result, result}, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, result: #{inspect result}")

    result = Response.stream_response(state.request.request_id, result, true)
    send(state.receiver, {:stream_response, result})

    {:noreply, state}
  end

  def handle_info({:error, error}, state) do
    Logger.error("lPhoenixGenApi.StreamCall, handle_info, error: #{inspect error}")

    error_message =
      if Application.get_env(:phoenix_gen_api, :detail_error, false) do
        "Internal Server Error: #{inspect error}"
      else
        "Internal Server Error"
      end

    result = Response.error_response(state.request.request_id, error_message)
    send(state.receiver, {:stream_call, result})

    done(state)

    {:stop, :error, state}
  end

  def handle_info(:complete, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, done")

    done(state)

    {:stop, :normal, state}
  end

  def handle_info(unknown, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, unknown message: #{inspect unknown}")

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("lPhoenixGenApi.StreamCall, terminate for request_id: #{inspect state.request.request_id}, reason: #{inspect reason}")

    :ok
  end

  defp done(state) do
    result = Response.stream_response(state.request.request_id, nil, false)

    send(state.receiver, {:stream_call, result})
  end

end
