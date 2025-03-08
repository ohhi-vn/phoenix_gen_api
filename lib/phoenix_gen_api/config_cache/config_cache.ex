defmodule PhoenixGenApi.ConfigCache do
  @moduledoc """
  This module provides a cache for `Executor` can get `%FunConfig{}` config by `request_type`.

  Use `:ets` to store config in memory.

  Application can add, update, delete, get config from this cache.

  `PhoenixGenApi.ConfigPuller` will pull config from nodes and update to this cache.

  """

  use GenServer, restart: :permanent

  alias __MODULE__

  alias PhoenixGenApi.Structs.{FunConfig}

  require Logger

  ### Public API

  @doc """
  Start the cache.
  """
  def start_link(opts \\ []) do
    Logger.info("PhoenixGenApi.ConfigCache, start_link")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a new config to cache.
  """
  @spec add(FunConfig.t()) :: :ok
  def add(request_config = %FunConfig{})  do
    GenServer.call(__MODULE__, {:insert, request_config})
  end

  @doc """
  Update a config in cache.
  """
  @spec update(FunConfig.t()) :: :ok | {:error, String.t()}
  def update(request_config = %FunConfig{}) do
    GenServer.call(__MODULE__, {:update, request_config})
  end

  @doc """
  Delete a config from cache.
  """
  @spec delete(String.t()) :: :ok
  def delete(request_type) do
    GenServer.call(__MODULE__, {:delete, request_type})
  end

  @doc """
  Get a config from cache.
  """
  @spec get(String.t()) :: FunConfig.t() | nil
  def get(request_type) do
    case :ets.lookup(ConfigCache, request_type) do
      [{_, config}] ->
        config
      [] ->
        Logger.warning("PhoenixGenApi.ConfigCache, get config, config not found for #{request_type}")
        nil
    end
  end

  @doc """
  Get all keys in cache.
  """
  @spec get_all_keys() :: [String.t()]
  def get_all_keys() do
    :ets.tab2list(ConfigCache)
    |> Enum.map(fn {key, _} -> key end)
  end

  ### Callbacks

  @impl true
  def init(_elements) do

    Logger.info("PhoenixGenApi.ConfigCache, init")

    # TO-DO: Load config to ets from database/config file.

    # Storage for game & player stats.
    # protected for worker can access directly.
    ConfigCache = :ets.new(ConfigCache, [:protected, :set, :named_table,
    read_concurrency: true
    ])

    ets = ConfigCache

    {:ok, %{table: ets}}
  end

  @impl true
  def handle_call({:insert, config}, _from, %{table: ets} = state) do
    :ets.insert(ets, {config.request_type, config})
    {:reply, :ok, state}
  end

  def handle_call({:update, config}, _from, %{table: ets} = state) do
    case :ets.lookup(ets, config.request_type) do
      [] ->
        {:reply, {:error, "Config not found"}, ets}
      [_|_] ->
        :ets.insert(ets, {config.request_type, config})
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, request_type}, _from,  %{table: ets} = state) do
    :ets.delete(ets, request_type)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state)

    :ok
  end
end
