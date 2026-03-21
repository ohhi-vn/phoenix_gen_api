defmodule PhoenixGenApi.ChannelHelpers do
  @moduledoc """
  Shared push-handling logic for GenApi WebSocket channels.

  Inject into a channel with `use PhoenixGenApi.ChannelHelpers`.
  Provides common `handle_info` clauses for:
    - synchronous push results
    - streaming responses
    - async RPC call results

  All three forward the payload to the client via the `"gen_api_result"` event.
  """

  defmacro __using__(_opts) do
    quote do
      @doc false
      def handle_info({:push, result}, socket) do
        require Logger
        Logger.debug(fn -> "#{__MODULE__}, push result: #{inspect(result)}" end)
        push(socket, "gen_api_result", result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:stream_response, result}, socket) do
        require Logger
        Logger.debug(fn -> "#{__MODULE__}, stream response: #{inspect(result)}" end)
        push(socket, "gen_api_result", result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:async_call, result}, socket) do
        require Logger

        Logger.debug(fn ->
          "#{__MODULE__}, async call result: #{inspect(result)}"
        end)

        push(socket, "gen_api_result", result)
        {:noreply, socket}
      end
    end
  end
end
