defmodule PhoenixGenApi.Structs.StreamHelper do
  @moduledoc """
  Helper struct and functions for sending streaming data to a `StreamCall` process.

  A `%StreamHelper{}` holds the PID of the stream process and the request ID.
  Use the provided functions to send data chunks, completion signals, and errors
  to the stream process, which forwards them to the client as `{:stream_response, response}`
  messages.

  ## Usage

      stream = %StreamHelper{stream_pid: pid, request_id: "req_123"}
      StreamHelper.send_result(stream, chunk_data)       # intermediate chunk
      StreamHelper.send_last_result(stream, final_data)   # final chunk
      StreamHelper.send_complete(stream)                   # normal completion
      StreamHelper.send_error(stream, reason)              # error
  """

  alias __MODULE__

  @typedoc "Stream helper struct."

  @type t :: %__MODULE__{
          stream_pid: pid(),
          request_id: String.t()
        }

  @derive Nestru.Decoder
  defstruct [
    # pid, the PID of the stream process.
    :stream_pid,
    # string, unique identifier for the request.
    :request_id
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
