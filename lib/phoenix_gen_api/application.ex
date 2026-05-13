defmodule PhoenixGenApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    client_mode = Application.get_env(:phoenix_gen_api, :client_mode, false)

    children =
      if client_mode do
        []
      else
        [
          # Rate limiter for global and per-API rate limiting
          PhoenixGenApi.RateLimiter,
          # Worker pools for async and stream execution
          PhoenixGenApi.WorkerPool.WorkerPoolSupervisor,
          # Configuration cache and puller
          PhoenixGenApi.ConfigDb,
          PhoenixGenApi.ConfigPuller,
          # Configuration receiver for remote node push
          PhoenixGenApi.ConfigReceiver
        ]
      end

    Logger.info(
      "[Application] starting, client_mode: #{inspect(client_mode)}, children: #{length(children)}"
    )

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # Use :rest_for_one so that if ConfigDb crashes and restarts (losing all cached configs),
    # the dependent processes (ConfigPuller, ConfigReceiver) also restart to re-populate
    # the cache. This avoids a window of unavailability where the cache is empty.
    opts = [strategy: :rest_for_one, name: PhoenixGenApi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
