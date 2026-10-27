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

  alias PhoenixGenApi.{ConfigDb, ConfigPuller, Security}
  alias PhoenixGenApi.LogContext
  alias PhoenixGenApi.Helpers.Shared
  alias PhoenixGenApi.Structs.{FunConfig, PushConfig, ServiceConfig}

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
  def get_all_pushed_services do
    GenServer.call(__MODULE__, :get_all_pushed_services)
  end

  @doc """
  Returns a status snapshot for the config receiver.
  """
  @spec status() :: map()
  def status do
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
    Logger.info(LogContext.event("ConfigReceiver", :init, node: node()))

    state = %{
      pushed_configs: %{},
      service_versions: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:push, config, force?}, from, state) do
    origin_node = from |> elem(0) |> node()

    result =
      try do
        LogContext.with_context(push_context(config, origin_node), fn ->
          do_push(config, force?, state, origin_node)
        end)
      rescue
        error ->
          Logger.error(
            LogContext.line(
              "ConfigReceiver",
              :push_internal_error,
              "push failed unexpectedly",
              LogContext.current(error: Exception.message(error))
            )
          )

          {:error, :internal_error, state}
      catch
        kind, reason ->
          Logger.error(
            LogContext.line(
              "ConfigReceiver",
              :push_internal_error,
              "push failed unexpectedly",
              LogContext.current(kind: kind, reason: reason)
            )
          )

          {:error, :internal_error, state}
      end

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

        Logger.info(
          LogContext.line(
            "ConfigReceiver",
            :deleted_pushed_service,
            "deleted pushed service",
            service: service,
            node: node()
          )
        )

        {:reply, :ok, new_state}
    end
  end

  ### Private - Push Logic

  defp do_push(raw_config, force?, state, origin_node) do
    with {:ok, config} <- decode_push_config(raw_config),
         :ok <- validate_push_config(config),
         :ok <- validate_push_token(config),
         :ok <- validate_push_admin(),
         :ok <- validate_push_source(config, origin_node),
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
    config = PushConfig.from_map(data)
    {:ok, config}
  rescue
    e ->
      Logger.error(
        LogContext.line(
          "ConfigReceiver",
          :push_decode_failed,
          "failed to decode PushConfig",
          LogContext.current(error: e)
        )
      )

      {:error, :invalid_push_config_data}
  end

  defp decode_push_config(other) do
    Logger.error(
      LogContext.line(
        "ConfigReceiver",
        :push_invalid_data_type,
        "push received invalid data type",
        LogContext.current(data: LogContext.payload(other))
      )
    )

    {:error, :invalid_push_config_data}
  end

  defp validate_push_config(config = %PushConfig{}) do
    case PushConfig.validate_with_details(config) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        {count, types} = push_request_types(config)

        Logger.error(
          LogContext.line(
            "ConfigReceiver",
            :push_validation_failed,
            "PushConfig validation failed",
            LogContext.current(
              errors: errors,
              request_type_count: count,
              request_types: types
            )
          )
        )

        {:error, {:validation_failed, errors}}
    end
  end

  defp validate_push_admin do
    if Application.get_env(:phoenix_gen_api, :admin_actions) == nil do
      :ok
    else
      if Security.admin_action_allowed?(:push_config) do
        :ok
      else
        Logger.warning(
          LogContext.line(
            "ConfigReceiver",
            :push_admin_denied,
            "push rejected: push_config admin action not allowed",
            LogContext.current()
          )
        )

        {:error, :admin_action_denied}
      end
    end
  end

  defp validate_push_source(%PushConfig{service: service, nodes: nodes}, origin_node) do
    listed? = node_listed?(origin_node, nodes)
    binding = Application.get_env(:phoenix_gen_api, :config_source_binding)
    owners = Application.get_env(:phoenix_gen_api, :service_owners)

    owner = owner_for(owners, service)
    owner_mismatch? = is_atom(owner) and not is_nil(owner) and owner != origin_node

    cond do
      binding && not listed? ->
        Logger.warning(
          LogContext.line(
            "ConfigReceiver",
            :push_source_rejected,
            "push rejected: origin not listed in pushed nodes",
            LogContext.current(origin_node: origin_node)
          )
        )

        {:error, :source_not_allowed}

      owner_mismatch? ->
        Logger.warning(
          LogContext.line(
            "ConfigReceiver",
            :push_owner_rejected,
            "push rejected: origin is not the service owner",
            LogContext.current(origin_node: origin_node, service_owner: owner)
          )
        )

        {:error, :source_not_allowed}

      not listed? ->
        Logger.warning(
          LogContext.line(
            "ConfigReceiver",
            :push_source_mismatch,
            "push origin is not listed in pushed nodes (binding disabled)",
            LogContext.current(origin_node: origin_node)
          )
        )

        :ok

      true ->
        :ok
    end
  end

  defp owner_for(nil, _service), do: nil

  defp owner_for(owners, service) when is_map(owners) do
    Map.get(owners, service) || Map.get(owners, to_string(service))
  end

  defp owner_for(_owners, _service), do: nil

  defp node_listed?(_origin, nodes) when not is_list(nodes), do: false

  defp node_listed?(origin, nodes) do
    Enum.any?(nodes, fn node -> to_string(node) == to_string(origin) end)
  end

  defp validate_push_token(%PushConfig{push_token: token}) do
    if Security.valid_push_token?(token) do
      :ok
    else
      Logger.warning(
        LogContext.line(
          "ConfigReceiver",
          :push_token_rejected,
          "push token rejected",
          LogContext.current(token_rejected: true)
        )
      )

      {:error, :invalid_push_token}
    end
  end

  defp maybe_skip_if_same_version(
         %PushConfig{config_version: version},
         true,
         _state
       ) do
    Logger.debug(fn ->
      LogContext.line(
        "ConfigReceiver",
        :force_push,
        "force push",
        LogContext.current(version: version)
      )
    end)

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
          LogContext.line(
            "ConfigReceiver",
            :push_skipped,
            "skipping push, version already stored",
            LogContext.current(version: version, reason: :version_matches)
          )
        )

        {:skip, :version_matches}

      stored when is_binary(stored) and is_binary(version) ->
        check_downgrade(stored, version)

      _ ->
        :ok
    end
  end

  defp check_downgrade(stored, version) do
    case {Version.parse(stored), Version.parse(version)} do
      {{:ok, stored_v}, {:ok, new_v}} ->
        case Version.compare(new_v, stored_v) do
          :lt ->
            if Application.get_env(:phoenix_gen_api, :reject_config_downgrades) do
              Logger.warning(
                LogContext.line(
                  "ConfigReceiver",
                  :push_downgrade_rejected,
                  "push rejected: version is older than the stored version",
                  LogContext.current(stored_version: stored, version: version)
                )
              )

              {:error, :version_downgrade}
            else
              Logger.warning(
                LogContext.line(
                  "ConfigReceiver",
                  :push_downgrade_allowed,
                  "accepting older version (downgrade rejection disabled)",
                  LogContext.current(stored_version: stored, version: version)
                )
              )

              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp prepare_fun_configs(%PushConfig{service: service, fun_configs: fun_configs}) do
    {prepared, {errors, rejected_types}} =
      Enum.flat_map_reduce(fun_configs, {[], []}, fn
        %FunConfig{} = config, {acc_errors, acc_types} ->
          config =
            config
            |> Shared.enforce_service_name(service)
            |> Shared.ensure_version()

          if FunConfig.valid?(config) do
            {[config], {acc_errors, acc_types}}
          else
            reasons =
              case FunConfig.validate_with_details(config) do
                {:error, errors} -> errors
                _ -> ["unknown validation error"]
              end

            error_msg =
              "invalid FunConfig: request_type=#{inspect(config.request_type)}, service=#{inspect(service)}, version=#{inspect(config.version)}, nodes: #{inspect(config.nodes)}, mfa: #{inspect(config.mfa)}, response_type: #{inspect(config.response_type)}, check_permission: #{inspect(config.check_permission)}"

            Logger.warning(
              LogContext.line(
                "ConfigReceiver",
                :invalid_fun_config,
                "invalid FunConfig",
                LogContext.current(
                  errors: reasons,
                  mfa: config.mfa,
                  nodes: config.nodes,
                  request_type: config.request_type,
                  version: config.version
                )
              )
            )

            PhoenixGenApi.ConfigFailed.record(config, reasons, :push, nil)
            {[], {[error_msg | acc_errors], [config.request_type | acc_types]}}
          end

        other, {acc_errors, acc_types} ->
          error_msg = "unexpected item in fun_configs: item=#{inspect(other)}"

          Logger.error(
            LogContext.line(
              "ConfigReceiver",
              :unexpected_fun_config,
              "unexpected item in fun_configs",
              LogContext.current(item: LogContext.payload(other))
            )
          )

          {[], {[error_msg | acc_errors], acc_types}}
      end)

    errors = Enum.reverse(errors)
    rejected_types = rejected_types |> Enum.reverse() |> Enum.uniq()

    if prepared == [] do
      Logger.error(
        LogContext.line(
          "ConfigReceiver",
          :no_valid_fun_configs,
          "no valid FunConfig items",
          LogContext.current(
            request_type_count: length(rejected_types),
            request_types: rejected_types,
            errors: errors
          )
        )
      )

      {:error, {:all_invalid, errors}}
    else
      if errors != [] do
        Logger.warning(
          LogContext.line(
            "ConfigReceiver",
            :partial_push,
            "partial push",
            LogContext.current(
              accepted_count: length(prepared),
              rejected_count: length(rejected_types),
              rejected_request_types: rejected_types,
              errors: errors
            )
          )
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
          LogContext.line(
            "ConfigReceiver",
            :push_stored,
            "stored configs",
            LogContext.current(
              config_version: version,
              count: count,
              request_types: prepared_configs |> Enum.map(& &1.request_type) |> Enum.uniq()
            )
          )
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
          LogContext.line(
            "ConfigReceiver",
            :batch_add_failed,
            "ConfigDb.batch_add failed",
            LogContext.current(reason: :all_invalid)
          )
        )

        {:error, :batch_add_failed, state}
    end
  end

  ### Private - ConfigPuller Integration

  defp maybe_register_with_puller(config = %PushConfig{}) do
    case PushConfig.to_service_config(config) do
      nil ->
        Logger.debug(fn ->
          LogContext.line(
            "ConfigReceiver",
            :auto_pull_skipped,
            "no auto-pull registration",
            LogContext.current(reason: :module_function_not_provided)
          )
        end)

        :ok

      %ServiceConfig{} = service_config ->
        Logger.info(
          LogContext.line(
            "ConfigReceiver",
            :puller_registration,
            "registering service with ConfigPuller",
            LogContext.current()
          )
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
          LogContext.line(
            "ConfigReceiver",
            :puller_unregistration,
            "unregistering service from ConfigPuller",
            LogContext.current(service: config.service)
          )
        )

        ConfigPuller.delete([service_config])
    end
  end

  defp push_context(%PushConfig{} = config, origin_node) do
    [
      service: LogContext.value(config.service),
      config_version: LogContext.value(config.config_version),
      origin_node: origin_node,
      node: node()
    ]
  end

  defp push_context(config, origin_node) when is_map(config) do
    [
      service: LogContext.value(Map.get(config, :service) || Map.get(config, "service")),
      config_version:
        LogContext.value(Map.get(config, :config_version) || Map.get(config, "config_version")),
      origin_node: origin_node,
      node: node()
    ]
  end

  defp push_context(_config, origin_node) do
    [service: :unknown, config_version: :unknown, origin_node: origin_node, node: node()]
  end

  defp push_request_types(%PushConfig{fun_configs: fun_configs}) when is_list(fun_configs) do
    types =
      for %FunConfig{request_type: request_type} <- fun_configs,
          not is_nil(request_type),
          do: request_type

    {length(types), Enum.take(types, 10)}
  end

  defp push_request_types(_config), do: {0, []}
end
