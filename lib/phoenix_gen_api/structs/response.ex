defmodule PhoenixGenApi.Structs.Response do
  @moduledoc """
  Response event from server to client.
  """

  alias __MODULE__

  @derive Nestru.Encoder
  defstruct [
    # string, unique id from request. Make by client.
    # send back to client for identify request.
    :request_id,
    # map, field -> value, result for request. If is async/stream
    # this field is empty for first time. Client must wait for next response.
    :result,
    # boolean, success or not. for case async/stream, server is processing
    success: false,
    # string, error message.
    error: "",
    # boolean, is async response or not.
    async: false,
    # boolean, indicates has more data for stream request.
    has_more: false,
  ]

  @doc """
  Create Request from params for convert data map from websocket api.
  """
  def encode!(res = %Response{}) do
    Nestru.encode!(res)
  end

  def error_response(request_id, error) do
    %Response{request_id: request_id, error: error}
  end

  def sync_response(request_id, result) do
    %Response{request_id: request_id, result: result, success: true}
  end

  def success_response(request_id, result) do
    %Response{request_id: request_id, result: result, success: true}
  end

  def async_response(request_id) do
    %Response{request_id: request_id, async: true, success: true}
  end

  def stream_response(request_id, result, has_more \\ true) do
    %Response{request_id: request_id, result: result, async: true, has_more: has_more}
  end

  def is_error?(%Response{success: false}), do: true
end
