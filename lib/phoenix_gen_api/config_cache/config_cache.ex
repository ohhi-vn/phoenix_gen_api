defmodule PhoenixGenApi.ConfigDb do
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
  Starts the `ConfigDb` GenServer.
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
  @spec delete(String.t(), String.t()) :: :ok
  def delete(service, request_type) do
    GenServer.call(__MODULE__, {:delete, {service, request_type}})
  end

  @doc """
  Retrieves a function configuration from the cache.

  Returns `{:ok, config}` if the configuration is found, or `{:error, :not_found}`
  if it is not.
  """
  @spec get(String.t(), String.t()) :: {:ok, FunConfig.t()} | {:error, :not_found}
  def get(service, request_type) do
    case :ets.lookup(__MODULE__, {service, request_type}) do
      [{_, config}] ->
        {:ok, config}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all request types (keys) in the cache.
  """
  @spec get_all_functions() :: %{String.t() => [String.t()]}
  def get_all_functions() do
    :ets.tab2list(__MODULE__)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {service, keys} -> {service, Enum.map(keys, &elem(&1, 1))} end)
    |> Enum.into(%{})
  end

  @doc """
  Returns a list of all request types (keys) in the cache.
  """
  @spec get_all_services() :: [String.t()]
  def get_all_services() do
    :ets.tab2list(__MODULE__)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {service, _} -> service end)
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
    :ets.insert(__MODULE__, {{config.service, config.request_type}, config})
    {:reply, :ok, state}
  end

  def handle_call({:update, config}, _from, state) do
    :ets.insert(__MODULE__, {{config.service, config.request_type}, config})
    {:reply, :ok, state}
  end

  def handle_call({:delete, {service, request_type}}, _from, state) do
    :ets.delete(__MODULE__, {service, request_type})
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
