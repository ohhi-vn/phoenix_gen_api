defmodule PhoenixGenApi do
  @moduledoc """
  PhoenixGenApi is a library to help you to generate API for Phoenix.

  Go to modules to see more details.
  """

  alias PhoenixGenApi.StreamCall

  @spec stop_stream(binary()) :: :ok
  @doc """
  Stop stream call from channel process.
  In this case the stream call will be stopped without notification to data generator process.
  Parameter `request_id` is the request id of that stream when the stream is created.
  """
  def stop_stream(request_id) do
    StreamCall.stop(request_id)
  end
end
