defmodule PhoenixGenApi.Structs.Response do
  @moduledoc """
  Defines the structure of a response sent back to the client.

  This module provides helper functions to create different types of responses,
  such as synchronous, asynchronous, and error responses.
  """

  @type t :: %__MODULE__{
          request_id: String.t(),
          result: any(),
          success: boolean(),
          error: String.t() | nil,
          async: boolean(),
          has_more: boolean(),
          can_retry: boolean()
        }

  @derive {Jason.Encoder,
           only: [:request_id, :result, :success, :error, :async, :has_more, :can_retry]}
  @derive Nestru.Encoder
  defstruct [
    :request_id,
    :result,
    success: false,
    error: nil,
    async: false,
    has_more: false,
    can_retry: false
  ]

  @doc """
  Creates a response for a successful synchronous request.
  """
  def sync_response(request_id, result) do
    %__MODULE__{request_id: request_id, result: result, success: true}
  end

  @doc """
  Creates a response for an asynchronous request, indicating that the request
  has been received and is being processed.
  """
  def async_response(request_id) do
    %__MODULE__{request_id: request_id, async: true, success: true}
  end

  @doc """
  Creates a response for a streaming request.
  """
  def stream_response(request_id, result, has_more \\ true) do
    %__MODULE__{
      request_id: request_id,
      result: result,
      async: true,
      has_more: has_more,
      success: true
    }
  end

  @doc """
  Creates a response to indicate the end of a stream.
  """
  def stream_end_response(request_id) do
    %__MODULE__{request_id: request_id, async: true, has_more: false, success: true}
  end

  @doc """
  Creates a response for a failed request.
  """
  def error_response(request_id, error, can_retry \\ false) do
    %__MODULE__{request_id: request_id, error: error, success: false, can_retry: can_retry}
  end

  @doc """
  Checks if the response represents an error.
  """
  def is_error?(%__MODULE__{success: false}), do: true
  def is_error?(%__MODULE__{}), do: false

  @doc """
  Create Request from params for convert data map from websocket api.
  """
  def encode!(res = %__MODULE__{}) do
    Nestru.encode!(res)
  end
end
