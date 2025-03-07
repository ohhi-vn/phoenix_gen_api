defmodule PhoenixGenApi.Executor do

  @moduledoc """
  This module is the core of PhoenixGenApi.
  It will execute the request from client and return the response.
  Response can be sync, async, or stream.

  This module will handle the request, check permission, convert args, and call the remote node.

  If the function is local, it will call the function directly.
  If the function is remote, it will call the function via RPC.

  If the function is sync, it will call the function and return the response immediately.
  If the function is async, it will spawn a new process to call the function and return the response immediately.
  If the function is stream, it will start a new process to handle the stream and return the response immediately.

  for case async and stream, the response will be sent to the client later Channel process will receive the response and send it to the client.

  """

  alias PhoenixGenApi.Structs.{Request, FunConfig, Response}
  alias PhoenixGenApi.ConfigCache, as: ConfigDb
  alias PhoenixGenApi.StreamCall

  alias :erpc, as: Rpc

  require Logger

  @doc """
  Execute a request from params.
  Params is a map from playload in Phoenix Channel event (handle_in).
  Function will raise an error if something wrong.

  Params:
    - request_id: String.t()
    - request_type: String.t()
    - user_id: String.t()
    - device_id: String.t()
    - args: map()
  """
  @spec execute_params!(map()) :: Response.t()
  def execute_params!(params) do
    request = Request.decode!(params)
    execute!(request)
  end

  @doc """
  Execute a request.
  """
  @spec execute!(Request.t()) :: Response.t()
  def execute!(request = %Request{}) do
    fun_config = ConfigDb.get(request.request_type)
    if fun_config == nil do
      Logger.warning("PhoenixGenApi.Executor, unsupported function, #{request.request_type}")
      # Return response message with error.
      Response.error_response(request.request_id, "unsupported function, #{request.request_type}")
    else
      Logger.debug("PhoenixGenApi.Executor, execute, response type: #{fun_config.response_type}, fun config: #{inspect fun_config}")

      # Check permission. Raise error if not pass.
      FunConfig.check_permission!(request, fun_config)

      case fun_config.response_type do
        :sync ->
          call(request, fun_config)
        :async ->
          async_call(request, fun_config)
        :stream ->
          Logger.error("PhoenixGenApi.Executor, unimplemented response type, stream")
          Response.error_response(request.request_id, "unimplemented response type, stream")
        _ ->
          Logger.error("PhoenixGenApi.Executor, unknown response type: #{inspect fun_config.response_type}")
          Response.error_response(request.request_id, "unknown response type")
      end
    end
  end

  def call(request = %Request{}, fun_config = %FunConfig{}) do
    args = FunConfig.convert_args!(fun_config, request)
    Logger.debug("PhoenixGenApi.Executor, remote call, converted args: #{inspect args}")

    info_args =
      if fun_config.request_info do
        [%{request_id: request.request_id, user_id: request.user_id, device_id: request.device_id}]
      else
        []
      end

    {mod, fun, predefined_args} = fun_config.mfa

    result = try do
      final_args = predefined_args ++ args ++ info_args

      if FunConfig.is_local_service?(fun_config) do
        Logger.debug("PhoenixGenApi.Executor, local call, prepare to call #{inspect mod}.#{inspect fun} locally args: #{inspect final_args}")

        apply(mod, fun, final_args)
      else
        node = FunConfig.get_node(fun_config, request)
        Logger.debug("PhoenixGenApi.Executor, remote call, prepare to call #{inspect mod}.#{inspect fun} on node #{inspect node} args: #{inspect final_args}")

        Rpc.call(node, mod, fun, final_args, fun_config.timeout)
      end
    rescue
      error ->
        Logger.error("PhoenixGenApi.Executor, remote call, got an error: #{inspect error}")
        {:error, "#{inspect error}"}
    catch
      error ->
        Logger.error("PhoenixGenApi.Executor, remote call, unexpected raise: #{inspect error}")
        {:error, error}
    end

    case result do
      {:error, reason} ->
        Logger.error("PhoenixGenApi.Executor, remote call, error: #{inspect reason}")
        Response.error_response(request.request_id, "internal server error, rpc")
      _ ->
        Logger.debug("PhoenixGenApi.Executor, remote call, success request_id: #{inspect request.request_id}, result: #{inspect result}")
        Response.success_response(request.request_id, result)
    end
  end

  @doc """
  Async call a request support for async response.
  """
  @spec async_call(Request.t(), FunConfig.t()) :: Response.t()
  def async_call(request = %Request{}, fun_config = %FunConfig{}) do
    # TO-DO: Move to GenServer/pool style.

    Logger.debug("PhoenixGenApi.Executor, async_call, request: #{inspect request}")
    receiver = self()

    # spawn_link for crash follow parent.
    spawn_link(fn ->
      Logger.debug("PhoenixGenApi.Executor, async_call, send request to remote node")
      result = call(request, fun_config)
      Logger.debug("PhoenixGenApi.Executor, async_call, result: #{inspect result}")

      send(receiver, {:async_call, result})
    end)

    Response.async_response(request.request_id)
  end

  @doc """
  Stream call a request support for stream response.
  """
  @spec stream_call(Request.t(), FunConfig.t()) :: Response.t()
  def stream_call(request = %Request{}, fun_config = %FunConfig{}) do
    # TO-DO: Move to pool style.

    Logger.debug("PhoenixGenApi.Executor, stream_call, request: #{inspect request}")

    result = StreamCall.start_link(%{request: request, fun_config: fun_config})

    Logger.debug("PhoenixGenApi.Executor, stream_call, start result: #{inspect result}")
    result
  end
end
