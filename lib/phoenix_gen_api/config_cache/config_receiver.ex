defmodule PhoenixGenApi.ConfigReceiver do
  @moduledoc """
  A server-side GenServer that receives pushed configs from remote nodes.

  Remote nodes can push their service configurations to the server/gateway node
  using this module. The receiver validates the pushed data, stores it in
  `ConfigDb`, and optionally registers the service with `ConfigPuller` for
  auto-pull.

  ## Push Mechanism

  When a remote node pushes a `PushConfig`, the receiver:

    1. Validates the `PushConfig` struct
    2. Compares the `config_version` with the locally stored version
    3. If the version matches (and `:force` is not set), the push is skipped
    4. If new or forced:
       - Validates all `FunConfig` items
       - Enforces the service name on each `FunConfig`
       - Ensures each `FunConfig` has a version (defaults to `"0.0.0"`)
       - Stores them in `ConfigDb` via `ConfigDb.batch_add/1`
       - Stores the `PushConfig` in state
       - If the `PushConfig` has `module`/`function` for auto-pull, registers
         it with `ConfigPuller` via `ConfigPuller.add/1`

  ## Atomicity

  The push operation is atomic — either all configs are stored or none. If
  validation fails for the `PushConfig` or any `FunConfig` item, the entire
  push is rejected.

  ## Important Notes

  - This module runs on the **server/gateway** node (not `client_mode`)
  - It should NOT be started when `client_mode: true`
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.Structs.{PushConfig, FunConfig, ServiceConfig}
  alias PhoenixGenApi.{ConfigDb, ConfigPuller}

  require Logger

  ### Public API

  @doc """
  Starts the `ConfigReceiver` GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Receives a `PushConfig` struct (or map that can be decoded into one).

  Validates the `PushConfig`, checks the version, and stores the configs
  if the version is new. If the `config_version` matches what is already
  stored, the push is skipped.

  ## Returns

    - `{:ok, :accepted}` - New configs were stored successfully
    - `{:ok, :skipped, reason}` - Push was skipped (e.g., version matches)
    - `{:error, reason}` - Validation failure
  """
  @spec push(PushConfig.t() | map()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push(config) do
    push(config, [])
  end

  @doc """
  Same as `push/1` but with options.

  ## Options

    - `:force` - Force push even if version matches (default: `false`)
  """
  @spec push(PushConfig.t() | map(), keyword()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push(config, opts) do
    force = Keyword.get(opts, :force, false)
    GenServer.call(__MODULE__, {:push, config, force})
  end

  @doc """
  Verifies that the server has the given service and `config_version`.

  ## Parameters

    - `service` - The service name (string or atom)
    - `config_version` - The config version string to verify

  ## Returns

    - `{:ok, :matched}` - Version matches what is stored
    - `{:ok, :mismatch, stored_version}` - Version differs from what is stored
    - `{:error, :not_found}` - Service is not known
  """
  @spec verify(String.t() | atom(), String.t()) ::
          {:ok, :matched} | {:ok, :mismatch, String.t()} | {:error, :not_found}
  def verify(service, config_version) do
    GenServer.call(__MODULE__, {:verify, service, config_version})
  end

  @doc """
  Returns the `PushConfig` for a given service name, or `nil`.
  """
  @spec get_pushed_config(String.t() | atom()) :: PushConfig.t() | nil
  def get_pushed_config(service) do
    GenServer.call(__MODULE__, {:get_pushed_config, service})
  end

  @doc """
  Returns a map of all pushed services and their config versions.
  """
  @spec get_all_pushed_services() :: %{(String.t() | atom()) => String.t()}
  def get_all_pushed_services() do
    GenServer.call(__MODULE__, :get_all_pushed_services)
  end

  @doc """
  Removes a pushed service from the receiver's state.

  Also removes the service from `ConfigPuller` if it was registered for
  auto-pull.
  """
  @spec delete_pushed_service(String.t() | atom()) :: :ok
  def delete_pushed_service(service) do
    GenServer.call(__MODULE__, {:delete_pushed_service, service})
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PhoenixGenApi.ConfigReceiver, init")

    state = %{
      pushed_configs: %{},
      service_versions: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:push, config, force?}, _from, state) do
    result = do_push(config, force?, state)

    case result do
      {:ok, :accepted, new_state} ->
        {:reply, {:ok, :accepted}, new_state}

      {:ok, :skipped, reason, state} ->
        {:reply, {:ok, :skipped, reason}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:verify, service, config_version}, _from, state) do
    case Map.get(state.service_versions, service) do
      nil ->
        {:reply, {:error, :not_found}, state}

      ^config_version ->
        {:reply, {:ok, :matched}, state}

      stored_version ->
        {:reply, {:ok, :mismatch, stored_version}, state}
    end
  end

  def handle_call({:get_pushed_config, service}, _from, state) do
    {:reply, Map.get(state.pushed_configs, service), state}
  end

  def handle_call(:get_all_pushed_services, _from, state) do
    {:reply, state.service_versions, state}
  end

  def handle_call({:delete_pushed_service, service}, _from, state) do
    case Map.get(state.pushed_configs, service) do
      nil ->
        {:reply, :ok, state}

      pushed_config ->
        # Remove from ConfigPuller if it was registered for auto-pull
        maybe_unregister_from_puller(pushed_config)

        new_state = %{
          state
          | pushed_configs: Map.delete(state.pushed_configs, service),
            service_versions: Map.delete(state.service_versions, service)
        }

        Logger.info("PhoenixGenApi.ConfigReceiver, deleted pushed service #{inspect(service)}")

        {:reply, :ok, new_state}
    end
  end

  ### Private - Push Logic

  defp do_push(raw_config, force?, state) do
    with {:ok, config} <- decode_push_config(raw_config),
         :ok <- validate_push_config(config),
         :ok <- maybe_skip_if_same_version(config, force?, state),
         {:ok, prepared_configs} <- prepare_fun_configs(config) do
      store_and_register(config, prepared_configs, state)
    else
      {:skip, reason} ->
        {:ok, :skipped, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp decode_push_config(%PushConfig{} = config), do: {:ok, config}

  defp decode_push_config(data) when is_map(data) do
    try do
      config = PushConfig.from_map(data)
      {:ok, config}
    rescue
      e ->
        Logger.error("PhoenixGenApi.ConfigReceiver, failed to decode PushConfig: #{inspect(e)}")

        {:error, :invalid_push_config_data}
    end
  end

  defp decode_push_config(other) do
    Logger.error(
      "PhoenixGenApi.ConfigReceiver, push received invalid data type: #{inspect(other)}"
    )

    {:error, :invalid_push_config_data}
  end

  defp validate_push_config(%PushConfig{} = config) do
    case PushConfig.validate_with_details(config) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        Logger.error(
          "PhoenixGenApi.ConfigReceiver, PushConfig validation failed: #{inspect(errors)}"
        )

        {:error, {:validation_failed, errors}}
    end
  end

  defp maybe_skip_if_same_version(
         %PushConfig{service: service, config_version: version},
         true,
         _state
       ) do
    Logger.debug(
      "PhoenixGenApi.ConfigReceiver, force push for service #{inspect(service)}, version #{inspect(version)}"
    )

    :ok
  end

  defp maybe_skip_if_same_version(
         %PushConfig{service: service, config_version: version},
         false,
         state
       ) do
    case Map.get(state.service_versions, service) do
      ^version ->
        Logger.warning(
          "PhoenixGenApi.ConfigReceiver, skipping push for service #{inspect(service)}, version #{inspect(version)} already stored"
        )

        {:skip, :version_matches}

      _ ->
        :ok
    end
  end

  defp prepare_fun_configs(%PushConfig{service: service, fun_configs: fun_configs}) do
    prepared =
      Enum.flat_map(fun_configs, fn
        %FunConfig{} = config ->
          config =
            config
            |> enforce_service_name(service)
            |> ensure_version()

          if FunConfig.valid?(config) do
            [config]
          else
            Logger.error(
              "PhoenixGenApi.ConfigReceiver, invalid FunConfig for #{inspect(config.request_type)} in service #{inspect(service)}"
            )

            []
          end

        other ->
          Logger.error(
            "PhoenixGenApi.ConfigReceiver, unexpected item in fun_configs: #{inspect(other)}"
          )

          []
      end)

    if prepared == [] do
      Logger.error(
        "PhoenixGenApi.ConfigReceiver, no valid FunConfig items for service #{inspect(service)}"
      )

      {:error, :no_valid_fun_configs}
    else
      {:ok, prepared}
    end
  end

  defp store_and_register(%PushConfig{} = config, prepared_configs, state) do
    service = config.service
    version = config.config_version

    case ConfigDb.batch_add(prepared_configs) do
      {:ok, count} ->
        :telemetry.execute(
          [:phoenix_gen_api, :config, :push],
          %{count: count},
          %{service: service, version: version}
        )

        Logger.info(
          "PhoenixGenApi.ConfigReceiver, stored #{count} configs for service #{inspect(service)} version #{inspect(version)}"
        )

        # Register with ConfigPuller if module/function are present
        maybe_register_with_puller(config)

        new_state = %{
          state
          | pushed_configs: Map.put(state.pushed_configs, service, config),
            service_versions: Map.put(state.service_versions, service, version)
        }

        {:ok, :accepted, new_state}

      {:error, :all_invalid} ->
        Logger.error(
          "PhoenixGenApi.ConfigReceiver, ConfigDb.batch_add reported all configs invalid for service #{inspect(service)}"
        )

        {:error, :batch_add_failed, state}
    end
  end

  ### Private - FunConfig Helpers

  defp enforce_service_name(config = %FunConfig{}, service_name) do
    if same_service?(config.service, service_name) do
      config
    else
      Logger.warning(
        "PhoenixGenApi.ConfigReceiver, service_name mismatch in FunConfig #{inspect(config.request_type)}, expected #{inspect(service_name)}, got #{inspect(config.service)}, overwriting"
      )

      %FunConfig{config | service: service_name}
    end
  end

  defp same_service?(fun_service, push_service)
       when is_atom(fun_service) and is_atom(push_service) do
    fun_service == push_service
  end

  defp same_service?(fun_service, push_service)
       when is_binary(fun_service) and is_binary(push_service) do
    fun_service == push_service
  end

  defp same_service?(fun_service, push_service)
       when is_atom(fun_service) and is_binary(push_service) do
    Atom.to_string(fun_service) == push_service
  end

  defp same_service?(fun_service, push_service)
       when is_binary(fun_service) and is_atom(push_service) do
    fun_service == Atom.to_string(push_service)
  end

  defp same_service?(_, _), do: false

  defp ensure_version(config = %FunConfig{}) do
    if Map.has_key?(config, :version) and is_binary(config.version) and
         byte_size(config.version) > 0 do
      config
    else
      Logger.debug(
        "PhoenixGenApi.ConfigReceiver, adding default version to config for #{inspect(config.request_type)}"
      )

      %FunConfig{config | version: "0.0.0"}
    end
  end

  ### Private - ConfigPuller Integration

  defp maybe_register_with_puller(%PushConfig{} = config) do
    case PushConfig.to_service_config(config) do
      nil ->
        Logger.debug(
          "PhoenixGenApi.ConfigReceiver, no auto-pull registration for service #{inspect(config.service)} (module/function not provided)"
        )

        :ok

      %ServiceConfig{} = service_config ->
        Logger.info(
          "PhoenixGenApi.ConfigReceiver, registering service #{inspect(config.service)} with ConfigPuller for auto-pull"
        )

        ConfigPuller.add([service_config])
    end
  end

  defp maybe_unregister_from_puller(%PushConfig{} = config) do
    case PushConfig.to_service_config(config) do
      nil ->
        :ok

      %ServiceConfig{} = service_config ->
        Logger.info(
          "PhoenixGenApi.ConfigReceiver, unregistering service #{inspect(config.service)} from ConfigPuller"
        )

        ConfigPuller.delete([service_config])
    end
  end
end
