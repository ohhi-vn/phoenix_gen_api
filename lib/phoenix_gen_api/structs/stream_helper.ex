defmodule PhoenixGenApi.Structs.StreamHelper do
  @moduledoc """
  Support for send data to stream.
  """

  alias __MODULE__

  @typedoc "Stream helper struct."

  @type t :: %__MODULE__{
    stream_pid: pid(),
    request_id: String.t(),
  }

  @derive Nestru.Decoder
  defstruct [
    # string, user's id in system.
    :stream_pid,
    # string, device id of user. can be
    :request_id,
  ]

  @doc """
  Wrap result & send to stream.
  """
  def send_result(stream = %StreamHelper{}, result) do
    send(stream.stream_pid, {:result, result})
  end

  @doc """
  Wrap last result & send to stream.
  """
  def send_last_result(stream = %StreamHelper{}, result) do
    send(stream.stream_pid, {:last_result, result})
  end

  @doc """
  Wrap complete & send to stream.
  """
  def send_complete(stream = %StreamHelper{}) do
    send(stream.stream_pid, :complete)
  end

  @doc """
  Wrap error & send to stream.
  """
  def send_error(stream = %StreamHelper{}, error) do
    send(stream.stream_pid, {:error, error})
  end
end
