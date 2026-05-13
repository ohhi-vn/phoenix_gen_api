defmodule PhoenixGenApi.ChannelHelpers do
  @moduledoc """
  Shared push-handling logic for GenApi WebSocket channels.

  Inject into a channel with `use PhoenixGenApi.ChannelHelpers`.

  Provides common `handle_info` clauses for:
    - synchronous push results
    - streaming responses
    - async RPC call results

  ## Configuration

  The event name used for pushing responses to the client can be configured
  via the `:event` option. This should match the event name used in the
  channel's `handle_in/3` clause.

      use PhoenixGenApi.ChannelHelpers, event: "my_custom_event"

  By default, the event name is `"phoenix_gen_api"`, consistent with the
  main `use PhoenixGenApi` macro.

  ## Migration from Previous Versions

  Previously, this module hardcoded the event name as `"gen_api_result"`.
  If you relied on that behavior, configure it explicitly:

      use PhoenixGenApi.ChannelHelpers, event: "gen_api_result"
  """

  defmacro __using__(opts) do
    event = Keyword.get(opts, :event, "phoenix_gen_api")

    quote location: :keep, bind_quoted: [event: event] do
      @phoenix_gen_api_channel_event event

      require Logger

      @doc false
      def handle_info({:push, result}, socket) do
        Logger.debug(fn ->
          "[ChannelHelpers] push result: #{inspect(result)}, module: #{__MODULE__}"
        end)

        push(socket, @phoenix_gen_api_channel_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:stream_response, result}, socket) do
        Logger.debug(fn ->
          "[ChannelHelpers] stream response: #{inspect(result)}, module: #{__MODULE__}"
        end)

        push(socket, @phoenix_gen_api_channel_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:async_call, result}, socket) do
        Logger.debug(fn ->
          "[ChannelHelpers] async call result: #{inspect(result)}, module: #{__MODULE__}"
        end)

        push(socket, @phoenix_gen_api_channel_event, result)
        {:noreply, socket}
      end

      @doc false
      def handle_info({:stream_started, request_id, pid}, socket) do
        Logger.debug(fn ->
          "[ChannelHelpers] stream started: request_id=#{inspect(request_id)}, module: #{__MODULE__}"
        end)

        {:noreply, socket}
      end
    end
  end
end
