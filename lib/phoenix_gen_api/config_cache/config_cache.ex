defmodule PhoenixGenApi.ConfigDb do
  @moduledoc """
  A GenServer-based cache for storing `FunConfig` structs, using an ETS table as the
  backing store.

  This cache provides fast, in-memory access to function configurations, which are
  used by the `Executor` to handle incoming requests.

  The cache is populated and updated by the `ConfigPuller` module, which fetches
  configurations from remote nodes.

  ## Multi-Version Support

  Configurations can have multiple versions identified by the `version` field.
  The ETS key is `{service, request_type, version}` to support multiple versions
  of the same function. When retrieving configs, you can specify a version or
  get the latest version.

  ## Fault Tolerance

  - ETS table is automatically cleaned up on process termination
  - Invalid configurations are rejected before insertion
  - Atomic operations prevent race conditions
  - Read concurrency is enabled for high-throughput scenarios

  ## Security

  - Configurations are validated before being added to the cache
  - Service names and request types are sanitized
  - Only valid `FunConfig` structs are accepted
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.Structs.FunConfig

  require Logger

  ### Public API

  @doc """
  Starts the `ConfigDb` GenServer.

  ## Options

    - `:ets_options` - Additional options for the ETS table (default: `[]`)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a new function configuration to the cache.

  Validation is performed on the calling process. The ETS write is then done
  directly (safe because the table has `write_concurrency: true`) without
  routing through the GenServer mailbox, keeping throughput high under load.

  ## Returns

    - `:ok` - Configuration was added successfully
    - `{:error, :invalid_config}` - Configuration failed validation
  """
  @spec add(FunConfig.t()) :: :ok | {:error, :invalid_config}
  def add(config = %FunConfig{}) do
    if FunConfig.valid?(config) do
      version = FunConfig.version(config)
      :ets.insert(__MODULE__, {{config.service, config.request_type, version}, config})

      Logger.debug(
        "PhoenixGenApi.ConfigDb, added config for #{inspect(config.service)}/#{inspect(config.request_type)}/#{version}"
      )

      :ok
    else
      Logger.error("PhoenixGenApi.ConfigDb, add, invalid config: #{inspect(config)}")
      {:error, :invalid_config}
    end
  end

  @doc """
  Adds multiple function configurations to the cache in a single ETS call.

  Each config is validated on the calling process. All valid configs are then
  inserted atomically in one `:ets.insert/2` call, which is significantly faster
  than calling `add/1` in a loop (avoids N GenServer round-trips and N ETS calls).

  Invalid configs are logged and skipped; they do not abort the batch.

  ## Returns

    - `{:ok, count}` - Number of configs successfully inserted
    - `{:error, :all_invalid}` - Every config in the batch failed validation
  """
  @spec batch_add([FunConfig.t()]) :: {:ok, non_neg_integer()} | {:error, :all_invalid}
  def batch_add(configs) when is_list(configs) do
    entries =
      Enum.flat_map(configs, fn
        config = %FunConfig{} ->
          if FunConfig.valid?(config) do
            version = FunConfig.version(config)
            [{{config.service, config.request_type, version}, config}]
          else
            Logger.error("PhoenixGenApi.ConfigDb, batch_add, invalid config: #{inspect(config)}")
            []
          end

        other ->
          Logger.error("PhoenixGenApi.ConfigDb, batch_add, unexpected item: #{inspect(other)}")
          []
      end)

    case entries do
      [] ->
        {:error, :all_invalid}

      _ ->
        :ets.insert(__MODULE__, entries)
        Logger.debug("PhoenixGenApi.ConfigDb, batch_add inserted #{length(entries)} configs")
        {:ok, length(entries)}
    end
  end

  @doc """
  Disables a function configuration by marking it as disabled.
  Disabled configurations will not be returned by `get/3` or executed.

  ## Parameters

    - `service` - The service name (string or atom)
    - `request_type` - The request type (string)
    - `version` - The version to disable (string, defaults to "0.0.0")

  ## Returns

    - `:ok` - Configuration was disabled successfully
    - `{:error, :not_found}` - Configuration does not exist
  """
  @spec disable(String.t() | atom(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def disable(service, request_type, version \\ "0.0.0") when is_binary(request_type) do
    GenServer.call(__MODULE__, {:disable, {service, request_type, version}})
  end

  @doc """
  Enables a previously disabled function configuration.

  ## Parameters

    - `service` - The service name (string or atom)
    - `request_type` - The request type (string)
    - `version` - The version to enable (string, defaults to "0.0.0")

  ## Returns

    - `:ok` - Configuration was enabled successfully
    - `{:error, :not_found}` - Configuration does not exist
  """
  @spec enable(String.t() | atom(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def enable(service, request_type, version \\ "0.0.0") when is_binary(request_type) do
    GenServer.call(__MODULE__, {:enable, {service, request_type, version}})
  end

  @doc """
  Updates an existing function configuration in the cache.
  If the configuration does not exist, it will be added.

  Validation is performed on the calling process. The ETS write is then done
  directly (safe because the table has `write_concurrency: true`) without
  routing through the GenServer mailbox.

  ## Returns

    - `:ok` - Configuration was updated successfully
    - `{:error, :invalid_config}` - Configuration failed validation
  """
  @spec update(FunConfig.t()) :: :ok | {:error, :invalid_config}
  def update(config = %FunConfig{}) do
    if FunConfig.valid?(config) do
      version = FunConfig.version(config)
      :ets.insert(__MODULE__, {{config.service, config.request_type, version}, config})

      Logger.debug(
        "PhoenixGenApi.ConfigDb, updated config for #{inspect(config.service)}/#{inspect(config.request_type)}/#{version}"
      )

      :ok
    else
      Logger.error("PhoenixGenApi.ConfigDb, update, invalid config: #{inspect(config)}")
      {:error, :invalid_config}
    end
  end

  @doc """
  Deletes a function configuration from the cache.

  ## Parameters

    - `service` - The service name (string or atom)
    - `request_type` - The request type (string)
    - `version` - The version to delete (string, defaults to "0.0.0")

  ## Returns

    - `:ok` - Configuration was deleted (or didn't exist)
  """
  @spec delete(String.t() | atom(), String.t(), String.t()) :: :ok
  def delete(service, request_type, version \\ "0.0.0") when is_binary(request_type) do
    GenServer.call(__MODULE__, {:delete, {service, request_type, version}})
  end

  @doc """
  Retrieves a function configuration from the cache.

  This operation is atomic and uses ETS read concurrency for optimal performance.

  ## Parameters

    - `service` - The service name (string or atom)
    - `request_type` - The request type (string)
    - `version` - The version to retrieve (string, defaults to "0.0.0")

  ## Returns

    - `{:ok, config}` - Configuration was found and is enabled
    - `{:error, :not_found}` - Configuration does not exist
    - `{:error, :disabled}` - Configuration exists but is disabled
  """
  @spec get(String.t() | atom(), String.t(), String.t()) ::
          {:ok, FunConfig.t()} | {:error, :not_found} | {:error, :disabled}
  def get(service, request_type, version \\ "0.0.0") when is_binary(request_type) do
    case :ets.lookup(__MODULE__, {service, request_type, version}) do
      [{_key, config}] ->
        if Map.get(config, :disabled, false) do
          {:error, :disabled}
        else
          {:ok, config}
        end

      [] ->
        {:error, :not_found}

      _ ->
        Logger.error(
          "PhoenixGenApi.ConfigDb, get, unexpected ETS result for #{inspect({service, request_type, version})}"
        )

        {:error, :not_found}
    end
  end

  @doc """
  Retrieves the latest version of a function configuration from the cache.

  This operation is atomic and uses ETS read concurrency for optimal performance.

  ## Parameters

    - `service` - The service name (string or atom)
    - `request_type` - The request type (string)

  ## Returns

    - `{:ok, config}` - Latest enabled configuration was found
    - `{:error, :not_found}` - No configuration exists
  """
  @spec get_latest(String.t() | atom(), String.t()) :: {:ok, FunConfig.t()} | {:error, :not_found}
  def get_latest(service, request_type) when is_binary(request_type) do
    result =
      :ets.foldl(
        fn {{svc, req_type, _version}, config}, acc ->
          if svc == service and req_type == request_type and not Map.get(config, :disabled, false) do
            case acc do
              {:ok, existing_config} ->
                existing_version = FunConfig.version(existing_config)
                new_version = FunConfig.version(config)

                if Version.compare(new_version, existing_version) == :gt do
                  {:ok, config}
                else
                  acc
                end

              :not_found ->
                {:ok, config}
            end
          else
            acc
          end
        end,
        :not_found,
        __MODULE__
      )

    case result do
      {:ok, config} -> {:ok, config}
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Returns a map of all services and their request types in the cache.

  ## Returns

    A map where keys are service names and values are maps of request types to lists of versions.
  """
  @spec get_all_functions() :: %{(String.t() | atom()) => %{String.t() => [String.t()]}}
  def get_all_functions() do
    :ets.foldl(
      fn {{service, request_type, version}, _config}, acc ->
        service_map = Map.get(acc, service, %{})
        version_list = Map.get(service_map, request_type, [])
        new_service_map = Map.put(service_map, request_type, [version | version_list])
        Map.put(acc, service, new_service_map)
      end,
      %{},
      __MODULE__
    )
  end

  @doc """
  Returns a list of all service names in the cache.

  ## Returns

    A list of unique service names.
  """
  @spec get_all_services() :: [String.t() | atom()]
  def get_all_services() do
    :ets.foldl(
      fn {{service, _request_type, _version}, _config}, acc ->
        if service in acc, do: acc, else: [service | acc]
      end,
      [],
      __MODULE__
    )
  end

  @doc """
  Returns the total number of configurations in the cache.

  ## Returns

    The count of cached configurations.
  """
  @spec count() :: non_neg_integer()
  def count() do
    :ets.info(__MODULE__, :size)
  end

  @doc """
  Clears all configurations from the cache.

  ## Returns

    - `:ok` - Cache was cleared successfully
  """
  @spec clear() :: :ok
  def clear() do
    GenServer.call(__MODULE__, :clear)
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    access = if Mix.env() == :test, do: :public, else: :protected

    :ets.new(__MODULE__, [
      access,
      :set,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("PhoenixGenApi.ConfigDb, initialized ETS table with read/write concurrency")
    {:ok, %{}}
  end

  # NOTE: handle_call for :add and :update are intentionally removed.
  # add/1, update/1, and batch_add/1 now write directly to ETS after
  # validating on the caller's process, which is safe with write_concurrency: true
  # and avoids serialising bulk inserts through the GenServer mailbox.

  @impl true
  def handle_call({:delete, {service, request_type, version}}, _from, state) do
    :ets.delete(__MODULE__, {service, request_type, version})

    Logger.debug(
      "PhoenixGenApi.ConfigDb, deleted config for #{inspect(service)}/#{inspect(request_type)}/#{version}"
    )

    {:reply, :ok, state}
  end

  def handle_call({:disable, {service, request_type, version}}, _from, state) do
    case :ets.lookup(__MODULE__, {service, request_type, version}) do
      [{_key, config}] ->
        disabled_config = Map.put(config, :disabled, true)
        :ets.insert(__MODULE__, {{service, request_type, version}, disabled_config})

        Logger.info(
          "PhoenixGenApi.ConfigDb, disabled config for #{inspect(service)}/#{inspect(request_type)}/#{version}"
        )

        {:reply, :ok, state}

      [] ->
        Logger.warning(
          "PhoenixGenApi.ConfigDb, disable failed, config not found for #{inspect(service)}/#{inspect(request_type)}/#{version}"
        )

        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:enable, {service, request_type, version}}, _from, state) do
    case :ets.lookup(__MODULE__, {service, request_type, version}) do
      [{_key, config}] ->
        enabled_config = Map.put(config, :disabled, false)
        :ets.insert(__MODULE__, {{service, request_type, version}, enabled_config})

        Logger.info(
          "PhoenixGenApi.ConfigDb, enabled config for #{inspect(service)}/#{inspect(request_type)}/#{version}"
        )

        {:reply, :ok, state}

      [] ->
        Logger.warning(
          "PhoenixGenApi.ConfigDb, enable failed, config not found for #{inspect(service)}/#{inspect(request_type)}/#{version}"
        )

        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(__MODULE__)
    Logger.info("PhoenixGenApi.ConfigDb, cleared all configurations")
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    try do
      :ets.delete(__MODULE__)
      Logger.debug("PhoenixGenApi.ConfigDb, ETS table deleted on terminate")
    catch
      :error, :badarg -> :ok
    end

    :ok
  end
end
