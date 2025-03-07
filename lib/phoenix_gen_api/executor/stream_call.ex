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
        %{receiver: self()}
      end
    GenServer.start_link(__MODULE__, args)
  end

  ## GenServer callbacks

  @impl true
  def init(args) do
    Logger.debug("PhoenixGenApi.StreamCall, init, args: #{inspect args}")

    {:ok, args, {:continue, :start_call}}
  end

  @impl true
  def handle_continue(:start_call, state) do
    result = Executor.call(state.request, state.fun_config)

    send(state.receiver, Response.stream_response(state.request.request_id, :ok))

    if Response.is_error?(result) do
      Logger.error("PhoenixGenApi.StreamCall, handle_continue, rpc failed, error: #{inspect result}")
      {:stop, :error, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:stream_call, :stop}, _from, state) do
    Logger.debug("PhoenixGenApi.StreamCall, stream_call, handle_call, stop")

    done(state)

    {:stop, :normal, state}
  end

  def handle_call({:stream_call, result}, _from, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_call, result: #{inspect result}")
    {:reply, {:stream_call, result}, state}
  end


  @impl true
  def handle_info({:result, result}, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, result: #{inspect result}")

    result = Response.stream_response(state.request.request_id, result)
    send(state.receiver, {:stream_call, result})

    {:noreply, state}
  end

  def handle_info({:last_result, result}, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, result: #{inspect result}")

    result = Response.stream_response(state.request.request_id, result, true)
    send(state.receiver, {:stream_call, result})

    {:noreply, state}
  end

  def handle_info({:error, error}, state) do
    Logger.error("lPhoenixGenApi.StreamCall, handle_info, error: #{inspect error}")

    result = Response.error_response(state.request.request_id, "internal server error, rpc")
    send(state.receiver, {:stream_call, result})

    {:stop, :error, state}
  end

  def handle_info(:complete, state) do
    Logger.debug("PhoenixGenApi.StreamCall, handle_info, done")

    done(state)

    {:stop, :normal, state}
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
