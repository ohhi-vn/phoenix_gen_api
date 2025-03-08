defmodule PhoenixGenApi.Structs.Request do
  @moduledoc """
  Request struct for internal using, convert data map from websocket api.

  Data from websocket api has payload like this:
  %{
    "request_id" => "request_id",
    "request_type" => "request_type",
    "user_id" => "user_id",
    "device_id" => "device_id",
    "args" => %{}
  }

  We need to convert it to struct for internal using.

  Like this:
  %PhoenixGenApi.Structs.Request{
    request_id: "request_id",
    request_type: "request_type",
    user_id: "user_id",
    device_id: "device_id",
    args: %{}
  }

  Explain:
  - user_id: string, user's id in system.
    User's id in system. It need to check permission.

  - device_id: string, device id of current connection.
    Device id of current connection.

  - request_type: string, request type.
    Request type. Using for identify function to call in system.

  - request_id: string, unique id for request. Make by client.
    Unique id for request. Make by client. Using for identify response.

  - args: map, field -> value, arguments for request.
    Arguments for request. Using for call function in system.
  """

  alias __MODULE__

  @derive Nestru.Decoder
  defstruct [
    # string, user's id in system.
    :user_id,
    # string, device id of current connection.
    :device_id,
    # string, request type.
    :request_type,
    # string, unique id for request. Make by client.
    :request_id,
    # map, field -> value, arguments for request.
    :args,
  ]

  @doc """
  Create Request from params for convert data map from websocket api.
  """
  def decode!(params = %{}) do
    Nestru.decode!(params, Request)
  end
end
