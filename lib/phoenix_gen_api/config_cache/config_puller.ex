defmodule PhoenixGenApi.ConfigPuller do
  @moduledoc """
  This module is responsible for periodically pulling function configurations (`%FunConfig{}`)
  from remote nodes and updating the `ConfigCache`.

  The puller's behavior can be configured in your `config.exs` file:

  ```elixir
  config :phoenix_gen_api, :gen_api,
    pull_timeout: 5_000,
    pull_interval: 30_000
  ```

  - `pull_timeout`: The timeout for each RPC call in milliseconds (default: 5000).
  - `pull_interval`: The interval between each pull operation in milliseconds (default: 30000).
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.ConfigCache
  alias PhoenixGenApi.Structs.{ServiceConfig, FunConfig}
  alias :erpc, as: Rpc

  require Logger

  @default_interval 30_000
  @default_timeout 5_000

  ### Public API

  @doc """
  Starts the `ConfigPuller` GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a list of services to the puller.
  The `services` argument must be a list of `%ServiceConfig{}` structs.
  """
  def add(services) when is_list(services) do
    if services == [] do
      Logger.warning("PhoenixGenApi.ConfigPuller, add empty list of services")
    else
      Enum.each(services, fn
        %ServiceConfig{} ->
          :ok

        other ->
          Logger.error("PhoenixGenApi.ConfigPuller, add, incorrect data type: #{inspect(other)}")
          raise ArgumentError, "nodes must be a list of ServiceConfig"
      end)

      GenServer.cast(__MODULE__, {:add, services})
    end
  end

  @doc """
  Forces an immediate pull of configurations from the registered services.
  """
  def pull() do
    GenServer.cast(__MODULE__, :pull)
  end

  @doc """
  Deletes a list of services from the puller.
  The `services` argument must be a list of `%ServiceConfig{}` structs.
  """
  def delete(services) when is_list(services) do
    if services == [] do
      Logger.warning("PhoenixGenApi.ConfigPuller, remove empty list of services")
    else
      Enum.each(services, fn
        %ServiceConfig{} ->
          :ok

        other ->
          Logger.error(
            "PhoenixGenApi.ConfigPuller, remove, incorrect data type: #{inspect(other)}"
          )

          raise ArgumentError, "nodes must be a list of ServiceConfig"
      end)

      GenServer.cast(__MODULE__, {:delete, services})
    end
  end

  @doc """
  Returns the map of services currently being pulled from.
  """
  def get_services() do
    GenServer.call(__MODULE__, :get_services)
  end

  @doc """
  Returns the list of APIs for a given service.
  """
  def get_api_list(service) do
    GenServer.call(__MODULE__, {:get_api_list, service})
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PhoenixGenApi.ConfigPuller, init")
    {:ok, %{services: %{}, api_list: %{}}, {:continue, :load_initial_data}}
  end

  @impl true
  def handle_continue(:load_initial_data, state) do
    Logger.debug("PhoenixGenApi.ConfigPuller, loading initial data")
    new_state = load_services_from_config(state)
    schedule_pull()
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:add, services}, state) do
    new_services =
      Enum.reduce(services, state.services, fn config, acc ->
        Map.put(acc, config.service, config)
      end)

    {:noreply, %{state | services: new_services}}
  end

  def handle_cast(:pull, state) do
    pull_and_update_cache(state.services, state.api_list)
    schedule_pull()
    {:noreply, state}
  end

  def handle_cast({:delete, services}, state) do
    new_services =
      Enum.reduce(services, state.services, fn config, acc ->
        Map.delete(acc, config.service)
      end)

    {:noreply, %{state | services: new_services}}
  end

  @impl true
  def handle_call(:get_services, _from, state) do
    {:reply, state.services, state}
  end

  def handle_call({:get_api_list, service}, _from, state) do
    {:reply, Map.get(state.api_list, service), state}
  end

  @impl true
  def handle_info(:pull, state) do
    new_api_list = pull_and_update_cache(state.services, state.api_list)
    schedule_pull()
    {:noreply, %{state | api_list: new_api_list}}
  end

  ### Private Functions

  defp load_services_from_config(state) do
    case Application.fetch_env(:phoenix_gen_api, :gen_api) do
      {:ok, config} ->
        services =
          config
          |> Keyword.get(:service_configs, [])
          |> Enum.reduce(%{}, fn service_map, acc ->
            config = ServiceConfig.from_map(service_map)
            Map.put(acc, config.service, config)
          end)

        Logger.debug(
          "PhoenixGenApi.ConfigPuller, loaded services from config: #{inspect(services)}"
        )

        %{state | services: services}

      :error ->
        Logger.warning(
          "PhoenixGenApi.ConfigPuller, :service_configs not found in application config"
        )

        state
    end
  end

  defp pull_and_update_cache(services, api_list) do
    Enum.reduce(services, api_list, fn {_key, service}, acc ->
      Logger.debug("PhoenixGenApi.ConfigPuller, pulling config from service: #{inspect(service)}")
      result = fetch_and_process_service(service)
      Map.put(acc, service.service, result)
    end)
  end

  defp fetch_and_process_service(service) do
    try do
      node = get_random_node(service.nodes)

      case Rpc.call(node, service.module, service.function, service.args, pull_timeout()) do
        {:ok, fun_list} when is_list(fun_list) ->
          process_fun_list(fun_list)

        other ->
          Logger.error("PhoenixGenApi.ConfigPuller, unexpected RPC result: #{inspect(other)}")
          []
      end
    rescue
      error ->
        Logger.error("PhoenixGenApi.ConfigPuller, RPC call failed: #{inspect(error)}")
        []
    catch
      kind, value ->
        Logger.error("PhoenixGenApi.ConfigPuller, unexpected error: #{kind}: #{inspect(value)}")
        []
    end
  end

  defp process_fun_list(fun_list) do
    Enum.reduce(fun_list, [], fn
      config = %FunConfig{}, acc ->
        Logger.info("PhoenixGenApi.ConfigPuller, adding config: #{inspect(config)}")
        ConfigCache.add(config)
        [config.service | acc]

      other, acc ->
        Logger.error("PhoenixGenApi.ConfigPuller, unexpected item in fun_list: #{inspect(other)}")
        acc
    end)
  end

  defp get_random_node([]) do
    raise ArgumentError, "nodes list cannot be empty"
  end

  defp get_random_node(nodes) when is_list(nodes) do
    Enum.random(nodes)
  end

  defp schedule_pull() do
    Process.send_after(self(), :pull, pull_interval())
  end

  defp pull_timeout,
    do: Application.get_env(:phoenix_gen_api, :gen_api, [])[:pull_timeout] || @default_timeout

  defp pull_interval,
    do: Application.get_env(:phoenix_gen_api, :gen_api, [])[:pull_interval] || @default_interval
end
