defmodule PhoenixGenApi.Structs.Request do
  @moduledoc """
  Request event struct from client.
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
