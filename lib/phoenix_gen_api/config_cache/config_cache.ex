defmodule PhoenixGenApi.ConfigCache do
  @moduledoc """
  A GenServer-based cache for storing `FunConfig` structs, using an ETS table as the
  backing store.

  This cache provides fast, in-memory access to function configurations, which are
  used by the `Executor` to handle incoming requests.

  The cache is populated and updated by the `ConfigPuller` module, which fetches
  configurations from remote nodes.
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.Structs.FunConfig

  require Logger

  ### Public API

  @doc """
  Starts the `ConfigCache` GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a new function configuration to the cache.
  """
  @spec add(FunConfig.t()) :: :ok
  def add(config = %FunConfig{}) do
    GenServer.call(__MODULE__, {:add, config})
  end

  @doc """
  Updates an existing function configuration in the cache.
  If the configuration does not exist, it will be added.
  """
  @spec update(FunConfig.t()) :: :ok
  def update(config = %FunConfig{}) do
    GenServer.call(__MODULE__, {:update, config})
  end

  @doc """
  Deletes a function configuration from the cache.
  """
  @spec delete(String.t()) :: :ok
  def delete(request_type) do
    GenServer.call(__MODULE__, {:delete, request_type})
  end

  @doc """
  Retrieves a function configuration from the cache.

  Returns `{:ok, config}` if the configuration is found, or `{:error, :not_found}`
  if it is not.
  """
  @spec get(String.t()) :: {:ok, FunConfig.t()} | {:error, :not_found}
  def get(request_type) do
    case :ets.lookup(__MODULE__, request_type) do
      [{_, config}] ->
        {:ok, config}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all request types (keys) in the cache.
  """
  @spec get_all_keys() :: [String.t()]
  def get_all_keys() do
    :ets.tab2list(__MODULE__)
    |> Enum.map(fn {key, _} -> key end)
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    access = if Mix.env() == :test, do: :public, else: :protected

    :ets.new(__MODULE__, [access, :set, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, config}, _from, state) do
    :ets.insert(__MODULE__, {config.request_type, config})
    {:reply, :ok, state}
  end

  def handle_call({:update, config}, _from, state) do
    :ets.insert(__MODULE__, {config.request_type, config})
    {:reply, :ok, state}
  end

  def handle_call({:delete, request_type}, _from, state) do
    :ets.delete(__MODULE__, request_type)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
