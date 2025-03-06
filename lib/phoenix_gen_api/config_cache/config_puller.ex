defmodule PhoenixGenApi.ConfigPuller do
  @moduledoc """
  This is automation module for pull config from nodes and update to local db.
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.ConfigCache, as: ConfigDb
  alias PhoenixGenApi.Structs.{ServiceConfig, FunConfig}

  alias :erpc, as: Rpc

  require Logger

  @interval 30_000
  @timeout 5_000

  ### Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add nodes to pull config from.
  Nodes is a list of %ServiceConfig{}.
  """
  def add(services) when is_list(services) do
    if services == [] do
      Logger.warning("PhoenixGenApi.ConfigPuller, add empty list of services")
    else
      Enum.each(services, fn
        %ServiceConfig{} ->
          :ok
        other ->
          Logger.error("PhoenixGenApi.ConfigPuller, add, incorrect data type: #{inspect other}")
          raise ArgumentError, "nodes must be a list of ServiceConfig"
      end)
      GenServer.cast(__MODULE__, {:add, services})
    end
  end

  @doc """
  Force pull config from nodes.
  """
  def pull() do
    GenServer.cast(__MODULE__, :pull)
  end

  @doc """
  Delete services from pull config from.
  Nodes is a list of %ServiceConfig{}.
  """
  def delete(services) when is_list(services) do
    if services == [] do
      Logger.warning("PhoenixGenApi.ConfigPuller, remove empty list of services")
    else
      Enum.each(services, fn
        %ServiceConfig{} ->
          :ok
        other ->
          Logger.error("PhoenixGenApi.ConfigPuller, remove, incorrect data type: #{inspect other}")
          raise ArgumentError, "nodes must be a list of ServiceConfig"
      end)
      GenServer.cast(__MODULE__, {:delete, services})
    end
  end

  @doc """
  Get nodes that will be pulled config from.
  """
  def get_services() do
    GenServer.call(__MODULE__, :get_services)
  end

  @doc """
  Get api list from node.
  """
  def get_api_list(service) do
    GenServer.call(__MODULE__, {:get_api_list, service})
  end

  ### Callbacks

  @impl true
  def init(_elements) do
    Logger.info("PhoenixGenApi.ConfigPuller, puller, init")
    {:ok, %{services: %{}, api_list: %{}}, {:continue, :load_data}}
  end

  @impl true
  def handle_continue(_, state) do
    Logger.debug("PhoenixGenApi.ConfigPuller, puller, load data")
    state =
      case Application.fetch_env(:location_service, :gen_api) do
        {:ok, config} ->
          services = config[:service_configs]
          Logger.debug("PhoenixGenApi.ConfigPuller, puller, read config: #{inspect services}")
          config_list =
            Enum.reduce(services, %{}, fn service, acc ->
              Logger.debug("PhoenixGenApi.ConfigPuller, puller, convert config: #{inspect service}")
              config = ServiceConfig.from_map(service)
              Map.put(acc, config.service, config)
            end)

          Logger.debug("PhoenixGenApi.ConfigPuller, puller, read config: #{inspect config_list}")

          Map.put(state, :services, config_list)
        :error ->
          Logger.warning("PhoenixGenApi.ConfigPuller, puller read config, config not found")
          state
      end

    send(self(), :pull)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:add, services}, %{services: current_services} = state) do
    new_services = Enum.reduce(services, current_services, fn config, acc ->
      Map.put(acc, config.service, config)
    end)

    {:noreply, Map.put(state, :services, new_services)}
  end

  def handle_cast(:pull, state) do
    send(self(), :pull)


    {:noreply, state}
  end

  def handle_cast({:delete, services}, %{service: current_services} = state) do
    new_services = Enum.reduce(services, current_services, fn config, acc ->
      Map.delete(acc, config.service)
    end)

    {:noreply, Map.put(state, :services, new_services)}
  end

  @impl true
  def handle_call(:get_services, _from, %{services: services} = state) do
    {:reply, services, state}
  end

  def handle_call({:get_api_list, service}, _from, %{api_list: api_list} = state) do
    {:reply,  Map.get(api_list, service), state}
  end

  @impl true
  def handle_info(:pull, %{services: services, api_list: api_list} = state) do
    Logger.debug("PhoenixGenApi.ConfigPuller, puller, pull config from services")

    api_list =
      Enum.reduce(services, api_list, fn {_key, service}, acc ->
        Logger.debug("PhoenixGenApi.ConfigPuller, puller, pull config from service: #{inspect service}")
        # Current version only support same api config for all nodes.
        node = service.nodes |> Enum.random()

        result =
          try do
            rpc_result = Rpc.call(node, service.module, service.function, service.args, @timeout)

            case rpc_result do
              {:ok, fun_list} when is_list(fun_list) ->
                Enum.reduce(fun_list, [], fn
                  config = %FunConfig{}, acc ->
                    Logger.info("PhoenixGenApi.ConfigPuller, puller, add config: #{inspect config}")
                    ConfigDb.add(config)

                    [config.service | acc]
                  other, acc ->
                    Logger.error("PhoenixGenApi.ConfigPuller, puller, unexpected return type: #{inspect other}")
                    acc
                end)
              other ->
                Logger.error("PhoenixGenApi.ConfigPuller, puller, unexpected return type: #{inspect other}")
                []
            end

          rescue
            error ->
              Logger.error("PhoenixGenApi.ConfigPuller, puller, got an error: #{inspect error}")
              []

          catch
            error ->
              Logger.error("PhoenixGenApi.ConfigPuller, puller, unexpected raise: #{inspect error}")
              []
          end

        Logger.debug("PhoenixGenApi.ConfigPuller, puller, api list from node #{node}: #{inspect result}")

        Map.put(acc, service.service, result)
      end)

    Process.send_after(self(), :pull, @interval)

    {:noreply, Map.put(state, :api_list, api_list)}
  end
end
