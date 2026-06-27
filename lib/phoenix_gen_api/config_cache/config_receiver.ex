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
       - Ensures each `FunConfig` has a version (defaults to `nil`)
       - The value `"0.0.0"` is reserved as a sentinel and cannot be explicitly registered
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
  alias PhoenixGenApi.{ConfigDb, ConfigPuller, Security}

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
  Returns a status snapshot for the config receiver.
  """
  @spec status() :: map()
  def status() do
    GenServer.call(__MODULE__, :status)
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
    Logger.info("[ConfigReceiver] init")

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

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: :ok,
       pushed_services: state.service_versions,
       pushed_configs: state.pushed_configs
     }, state}
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

        Logger.info("[ConfigReceiver] deleted pushed service: service=#{inspect(service)}")

        {:reply, :ok, new_state}
    end
  end

  ### Private - Push Logic

  defp do_push(raw_config, force?, state) do
    with {:ok, config} <- decode_push_config(raw_config),
         :ok <- validate_push_config(config),
         :ok <- validate_push_token(config),
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

  defp decode_push_config(config = %PushConfig{}), do: {:ok, config}

  defp decode_push_config(data) when is_map(data) do
    try do
      config = PushConfig.from_map(data)
      {:ok, config}
    rescue
      e ->
        Logger.error("[ConfigReceiver] failed to decode PushConfig: error=#{inspect(e)}")

        {:error, :invalid_push_config_data}
    end
  end

  defp decode_push_config(other) do
    Logger.error("[ConfigReceiver] push received invalid data type: data=#{inspect(other)}")

    {:error, :invalid_push_config_data}
  end

  defp validate_push_config(config = %PushConfig{}) do
    case PushConfig.validate_with_details(config) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        Logger.error("[ConfigReceiver] PushConfig validation failed: errors=#{inspect(errors)}")

        {:error, {:validation_failed, errors}}
    end
  end

  defp validate_push_token(%PushConfig{push_token: token, service: service}) do
    if Security.valid_push_token?(token) do
      :ok
    else
      Logger.warning(
        "[ConfigReceiver] push token rejected: service=#{inspect(service)} token=#{inspect(token)}"
      )

      {:error, :invalid_push_token}
    end
  end

  defp maybe_skip_if_same_version(
         %PushConfig{service: service, config_version: version},
         true,
         _state
       ) do
    Logger.debug(
      "[ConfigReceiver] force push: service=#{inspect(service)} version=#{inspect(version)}"
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
          "[ConfigReceiver] skipping push: service=#{inspect(service)} version=#{inspect(version)} already stored"
        )

        {:skip, :version_matches}

      _ ->
        :ok
    end
  end

  defp prepare_fun_configs(%PushConfig{service: service, fun_configs: fun_configs}) do
    {prepared, errors} =
      Enum.flat_map_reduce(fun_configs, [], fn
        %FunConfig{} = config, acc_errors ->
          config =
            config
            |> PhoenixGenApi.Helpers.Shared.enforce_service_name(service)
            |> PhoenixGenApi.Helpers.Shared.ensure_version()

          if FunConfig.valid?(config) do
            {[config], acc_errors}
          else
            reasons =
              case FunConfig.validate_with_details(config) do
                {:error, errors} -> errors
                _ -> ["unknown validation error"]
              end

            error_msg =
              "invalid FunConfig: request_type=#{inspect(config.request_type)}, service=#{inspect(service)}, version=#{inspect(config.version)}, nodes: #{inspect(config.nodes)}, mfa: #{inspect(config.mfa)}, response_type: #{inspect(config.response_type)}, check_permission: #{inspect(config.check_permission)}"

            Logger.error("[ConfigReceiver] #{error_msg}")
            PhoenixGenApi.ConfigFailed.record(config, reasons, :push, nil)
            {[], [error_msg | acc_errors]}
          end

        other, acc_errors ->
          error_msg = "unexpected item in fun_configs: item=#{inspect(other)}"
          Logger.error("[ConfigReceiver] #{error_msg}")
          {[], [error_msg | acc_errors]}
      end)

    if prepared == [] do
      Logger.error("[ConfigReceiver] no valid FunConfig items: service=#{inspect(service)}")

      {:error, {:all_invalid, Enum.reverse(errors)}}
    else
      if errors != [] do
        Logger.warning(
          "[ConfigReceiver] partial push: #{length(prepared)} valid, #{length(errors)} invalid, service=#{inspect(service)}, errors: #{inspect(Enum.reverse(errors))}"
        )
      end

      {:ok, prepared}
    end
  end

  defp store_and_register(config = %PushConfig{}, prepared_configs, state) do
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
          "[ConfigReceiver] stored configs: service=#{inspect(service)} version=#{inspect(version)} count=#{count}"
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
          "[ConfigReceiver] ConfigDb.batch_add failed: service=#{inspect(service)} reason=all_invalid"
        )

        {:error, :batch_add_failed, state}
    end
  end

  ### Private - ConfigPuller Integration

  defp maybe_register_with_puller(config = %PushConfig{}) do
    case PushConfig.to_service_config(config) do
      nil ->
        Logger.debug(
          "[ConfigReceiver] no auto-pull registration: service=#{inspect(config.service)} reason=module_function_not_provided"
        )

        :ok

      %ServiceConfig{} = service_config ->
        Logger.info(
          "[ConfigReceiver] registering service with ConfigPuller: service=#{inspect(config.service)}"
        )

        ConfigPuller.add([service_config])
    end
  end

  defp maybe_unregister_from_puller(config = %PushConfig{}) do
    case PushConfig.to_service_config(config) do
      nil ->
        :ok

      %ServiceConfig{} = service_config ->
        Logger.info(
          "[ConfigReceiver] unregistering service from ConfigPuller: service=#{inspect(config.service)}"
        )

        ConfigPuller.delete([service_config])
    end
  end
end
