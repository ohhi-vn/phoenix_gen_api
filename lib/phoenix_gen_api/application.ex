defmodule PhoenixGenApi.Application do
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
          PhoenixGenApi.ConfigReceiver,
          # Registry for relay group membership (pid dispatch)
          {Registry, keys: :duplicate, name: PhoenixGenApi.RelayRegistry},
          # Relay group GenServer — serializes all ETS operations
          PhoenixGenApi.RelayServer
        ]
      end

    Logger.info(
      "[Application] starting, client_mode: #{inspect(client_mode)}, children: #{length(children)}"
    )

    opts = [strategy: :rest_for_one, name: PhoenixGenApi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
