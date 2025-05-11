defmodule PhoenixGenApi.Structs.Response do
  @moduledoc """
  Response struct for internal using, convert data map from websocket api.

  Data after pass throught websocket api client will received a event has payload like this:

  ```Elixir
  %{
    "request_id" => "request_id",
    "result" => data or null,
    "success" => boolean,
    "error" => string if has error,
    "async" => boolean,
    "has_more" => boolean
  }
  ```

  Internal struct like:

  ```Elixir
  %PhoenixGenApi.Structs.Response{
    request_id: "request_id",
    result: data or nil,
    success: boolean,
    error: string if has error,
    async: boolean,
    has_more: boolean
  }
  ```

  Explain:
  - request_id: string, unique id from request. Make by client.
    send back to client for identify request.

  - result: map, field -> value, result for request. If is async/stream
    this field is null for first time. Client must wait for next response.

  - success: boolean, success or not. for case async/stream, server is processing

  - error: string, error message.

  - async: boolean, is async response or not.

  - has_more: boolean, indicates has more data for stream request.

  For Phoenix can convert result to json and send to client,
  we need to make sure data can be convert to json.
  Or we need implement a Jason.Encoder for our struct.

  If Struct has function `encode!`, can use macro `use PhoenixGenApi.JasonImplHelpe` to generate Jason.Encoder implementation.
  """

  alias __MODULE__


  @typedoc "Response struct for internal using."

  @type t :: %__MODULE__{
    request_id: String.t(),
    result: map(),
    success: boolean,
    error: String.t(),
    async: boolean,
    has_more: boolean
  }

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
  def is_error?(%Response{}), do: false
end
