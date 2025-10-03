defmodule PhoenixGenApi.Executor do
  @moduledoc """
  The core execution engine of PhoenixGenApi.

  This module is responsible for taking a `Request` struct, looking up its
  corresponding `FunConfig`, and executing the function call according to the
  configuration. It handles synchronous, asynchronous, and streaming responses.
  """

  alias PhoenixGenApi.Structs.{Request, FunConfig, Response}
  alias PhoenixGenApi.ConfigCache
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Permission

  require Logger

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
    case ConfigCache.get(request.request_type) do
      {:ok, fun_config} ->
        execute_with_config!(request, fun_config)

      {:error, :not_found} ->
        Logger.warning("PhoenixGenApi.Executor, unsupported function: #{request.request_type}")

        Response.error_response(
          request.request_id,
          "unsupported function: #{request.request_type}"
        )
    end
  end

  def execute_with_config!(request = %Request{}, fun_config = %FunConfig{}) do
    Logger.debug(
      "PhoenixGenApi.Executor, executing request: #{request.request_id}, " <>
        "response_type: #{fun_config.response_type}"
    )

    if Permission.check_permission(request, fun_config) do
      case fun_config.response_type do
        :sync -> sync_call(request, fun_config)
        :async -> async_call(request, fun_config)
        :none -> async_call(request, fun_config)
        :stream -> stream_call(request, fun_config)
      end
    else
      Response.error_response(request.request_id, "Permission denied")
    end
  end

  defp sync_call(request, fun_config) do
    try do
      do_call(request, fun_config)
    rescue
      e in [RuntimeError] ->
        Logger.error("PhoenixGenApi.Executor, call failed: #{inspect(e)}")
        Response.error_response(request.request_id, "Internal Server Error")
    catch
      :exit, reason ->
        Logger.error("PhoenixGenApi.Executor, call exited: #{inspect(reason)}")
        Response.error_response(request.request_id, "Internal Server Error")
    end
  end

  defp do_call(request, fun_config) do
    args = ArgumentHandler.convert_args!(fun_config, request)
    {mod, fun, predefined_args} = fun_config.mfa

    final_args = predefined_args ++ args ++ info_args(request, fun_config)

    result =
      if FunConfig.is_local_service?(fun_config) do
        apply(mod, fun, final_args)
      else
        node = NodeSelector.get_node(fun_config, request)
        :rpc.call(node, mod, fun, final_args, fun_config.timeout)
      end

    handle_call_result(result, request.request_id)
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
  end

  defp handle_call_result({:error, reason}, request_id) do
    error_message =
      if Application.get_env(:phoenix_gen_api, :detail_error, false) do
        "Internal Server Error: #{inspect(reason)}"
      else
        "Internal Server Error"
      end

    Response.error_response(request_id, error_message)
  end

  defp handle_call_result(result, request_id) do
    Response.sync_response(request_id, result)
  end

  defp async_call(request, fun_config) do
    receiver = self()
    # TODO: Replace with a worker pool for better performance.
    spawn_link(fn ->
      result = sync_call(request, fun_config)

      if fun_config.response_type != :none do
        send(receiver, {:async_call, result})
      end
    end)

    if fun_config.response_type != :none do
      Response.async_response(request.request_id)
    else
      {:ok, :no_response}
    end
  end

  defp stream_call(request = %Request{}, fun_config = %FunConfig{}) do
    # TODO: Replace with a worker pool for better performance.
    case StreamCall.start_link(%{request: request, fun_config: fun_config, receiver: self()}) do
      {:ok, pid} ->
        Process.put({:phoenix_gen_api, :stream_call_pid, request.request_id}, pid)
        Response.stream_response(request.request_id, :init)

      {:error, reason} ->
        Logger.error("PhoenixGenApi.Executor, stream_call failed: #{inspect(reason)}")
        Response.error_response(request.request_id, "Failed to start stream")
    end
  end
end
