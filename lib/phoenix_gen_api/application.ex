defmodule PhoenixGenApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    client_mode = Application.get_env(:phoenix_gen_api, :client_mode, false)

    Logger.info("PhoenixGenApi.Application, start, client_mode: #{inspect client_mode}")

    children =
      if client_mode do
        []
      else
        # TO-DO: Add config number of pullers
        [
          PhoenixGenApi.ConfigCache,
          PhoenixGenApi.ConfigPuller,
        ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixGenApi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
