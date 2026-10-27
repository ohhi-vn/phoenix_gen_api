defmodule PhoenixGenApi.ConfigPuller do
  @moduledoc """
  This module is responsible for periodically pulling function configurations (`%FunConfig{}`)
  from remote nodes and updating the `ConfigDb`.

  ## Security

  MFA safety validation is performed on remote modules before configs are stored.
  When RPC verification fails (e.g., node unreachable), the config is **rejected** rather
  than accepted — this is a more secure default than the previous behavior which allowed
  configs when verification couldn't be completed.

  The puller's behavior can be configured in your `config.exs` file:

  ```elixir
  config :phoenix_gen_api, :gen_api,
    pull_timeout: 5_000,
    pull_interval: 30_000
  ```

  - `pull_timeout`: The timeout for each RPC call in milliseconds (default: 5000).
  - `pull_interval`: The interval between each pull operation in milliseconds (default: 30000).

  ## Version-Based Skip Mechanism

  When a `ServiceConfig` has `version_module` and `version_function` configured, the puller
  will first call the lightweight version check RPC before performing a full config pull.
  If the returned version matches the locally stored version for that service, the full
  pull is skipped — saving network bandwidth and reducing load on remote nodes.

  The remote service should implement a version function that returns a value that changes
  whenever the function configurations change. Good candidates include:

    - A monotonically increasing integer (e.g., `1`, `2`, `3`)
    - A semantic version string (e.g., `"1.2.3"`)
    - A content hash of the config data (e.g., `"a1b2c3d4"`)
    - A timestamp of the last config change (e.g., `"2024-01-15T10:30:00Z"`)

  The version value is compared using strict equality (`==`), so any format that can be
  compared this way will work.

  If `version_module` or `version_function` is `nil`, version checking is disabled and
  the full config pull will always be performed (backward compatible behavior).

  Use `force_pull/0` to force a full pull regardless of version matching, which clears
  all stored versions and re-fetches every service's configuration.

  ## Fault Tolerance

  - Failed RPC calls are logged and do not crash the puller
  - Node lists are validated before use
  - Configuration validation prevents invalid configs from entering the cache
  - Exponential backoff on repeated failures (up to a maximum)
  - Version check failures fall back to full pull

  ## Startup Behavior

  On application start, the puller loads service configurations from the application
  env and schedules an initial pull after 1 second. If the initial pull fails (e.g.,
  service nodes are unreachable), the puller logs a warning and continues retrying
  with exponential backoff (up to 300_000ms between attempts).

  The puller does **not** block application startup — the gateway will start even if
  service nodes are unreachable. APIs will be registered once the first successful
  pull completes. A recovery log message is emitted when a pull succeeds after
  previous failures.

  ## Security

  - Validates that remote configs match the expected service name
  - Validates FunConfig structs before adding to cache
  - Rejects configs with invalid MFAs or node configurations
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Helpers.Shared
  alias PhoenixGenApi.Structs.{FunConfig, ServiceConfig}

  alias PhoenixGenApi.LogContext

  require Logger

  @default_interval 30_000
  @default_timeout 5_000
  @max_backoff_interval 300_000
  @backoff_multiplier 2

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
    cond do
      services == [] ->
        Logger.warning(LogContext.event("ConfigPuller", :add_empty_services, node: node()))

      true ->
        Enum.each(services, fn
          %ServiceConfig{} ->
            :ok

          other ->
            Logger.error(
              LogContext.line(
                "ConfigPuller",
                :add_invalid_item,
                "add: incorrect data type",
                item_type: LogContext.value(LogContext.type_name(other))
              )
            )

            raise ArgumentError, "nodes must be a list of ServiceConfig"
        end)

        with :ok <- puller_admin_gate(),
             :ok <- validate_services(services) do
          GenServer.cast(__MODULE__, {:add, services})
          :ok
        end
    end
  end

  defp puller_admin_gate do
    if Application.get_env(:phoenix_gen_api, :protect_config_puller) == true and
         Application.get_env(:phoenix_gen_api, :admin_actions) != nil do
      if PhoenixGenApi.Security.admin_action_allowed?(:push_config) do
        :ok
      else
        {:error, :admin_action_denied}
      end
    else
      :ok
    end
  end

  defp validate_services(services) do
    Enum.reduce_while(services, :ok, fn service, _acc ->
      case validate_service_config(service) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_service_config(
         %ServiceConfig{module: module, function: function, args: args} = service
       ) do
    with :ok <- PhoenixGenApi.Security.validate_mfa({module, function, args}),
         :ok <- validate_pull_nodes(service.nodes) do
      :ok
    else
      {:error, {:mfa_not_allowed, _}} ->
        {:error, {:invalid_service_config, :mfa_not_allowed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_pull_nodes(nodes) when is_list(nodes) do
    case Application.get_env(:phoenix_gen_api, :pull_node_allowlist) do
      nil ->
        :ok

      allowlist when is_list(allowlist) ->
        allowed = Enum.map(allowlist, &to_string/1)
        disallowed = Enum.reject(nodes, fn node -> to_string(node) in allowed end)

        if disallowed == [] do
          :ok
        else
          {:error, {:node_not_allowed, disallowed}}
        end

      _ ->
        :ok
    end
  end

  defp validate_pull_nodes(_nodes), do: :ok

  @doc """
  Triggers an immediate pull of configurations from the registered services.
  Version checking is respected — if the stored version matches the remote version,
  the full pull for that service is skipped.
  """
  def pull do
    GenServer.cast(__MODULE__, :pull)
  end

  @doc """
  Forces an immediate full pull of configurations from all registered services,
  ignoring version checking. This clears all stored versions first, so every
  service will be re-fetched regardless of whether its version has changed.

  Use this when you want to guarantee a fresh configuration pull, for example
  after a deployment or when you suspect the local cache is stale.
  """
  def force_pull do
    with :ok <- puller_admin_gate() do
      GenServer.cast(__MODULE__, :force_pull)
      :ok
    end
  end

  @doc """
  Returns a status snapshot for the config puller.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Deletes a list of services from the puller.
  The `services` argument must be a list of `%ServiceConfig{}` structs.

  Deleting a service also removes its stored version and API list entry.
  """
  def delete(services) when is_list(services) do
    if services == [] do
      Logger.warning(LogContext.event("ConfigPuller", :remove_empty_services, node: node()))
    else
      Enum.each(services, fn
        %ServiceConfig{} ->
          :ok

        other ->
          Logger.error(
            LogContext.line(
              "ConfigPuller",
              :remove_invalid_item,
              "remove: incorrect data type",
              item_type: LogContext.value(LogContext.type_name(other))
            )
          )

          raise ArgumentError, "nodes must be a list of ServiceConfig"
      end)

      GenServer.cast(__MODULE__, {:delete, services})
    end
  end

  @doc """
  Returns the map of services currently being pulled from.
  """
  def get_services do
    GenServer.call(__MODULE__, :get_services)
  end

  @doc """
  Returns the list of APIs for a given service.
  """
  def get_api_list(service) do
    GenServer.call(__MODULE__, {:get_api_list, service})
  end

  @doc """
  Returns the stored config version for a given service.

  Returns `nil` if no version has been stored for the service. This indicates
  that either the service hasn't been pulled yet, or version checking is not
  configured for the service and no version was captured from a previous pull.
  """
  @spec get_service_version(String.t() | atom()) :: term() | nil
  def get_service_version(service) do
    GenServer.call(__MODULE__, {:get_service_version, service})
  end

  @doc """
  Returns a map of all stored service versions.

  The map keys are service names and the values are the stored version terms.
  Services that were pulled without version checking configured will have `nil`
  as their version value.
  """
  @spec get_all_versions() :: %{(String.t() | atom()) => term()}
  def get_all_versions do
    GenServer.call(__MODULE__, :get_all_versions)
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    Logger.info(LogContext.event("ConfigPuller", :init, node: node()))

    state = %{
      services: %{},
      api_list: %{},
      service_versions: %{},
      failure_count: 0,
      pulling?: false,
      pull_ref: nil,
      pull_pending?: false
    }

    {:ok, state, {:continue, :load_initial_data}}
  end

  @impl true
  def handle_continue(:load_initial_data, state) do
    Logger.info(LogContext.event("ConfigPuller", :loading_initial_data, node: node()))
    new_state = load_services_from_config(state)

    if map_size(new_state.services) > 0 do
      Logger.info(
        LogContext.line(
          "ConfigPuller",
          :initial_pull_scheduled,
          "starting initial pull",
          services: Map.keys(new_state.services)
        )
      )
    else
      Logger.warning(
        LogContext.event("ConfigPuller", :no_services_configured,
          message: "no services configured, waiting for service registration"
        )
      )
    end

    Process.send_after(self(), :pull, 1_000)
    # Schedule sticky table cleanup every hour
    Process.send_after(self(), :cleanup_sticky, 3_600_000)
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
    {:noreply, start_pull(state, false)}
  end

  def handle_cast(:force_pull, state) do
    # Clear all stored versions so that version checks will always fail,
    # forcing a full pull for all services regardless of version changes.
    {:noreply, start_pull(%{state | service_versions: %{}}, true)}
  end

  def handle_cast({:delete, services}, state) do
    deleted_names = Enum.map(services, & &1.service)

    new_services =
      Enum.reduce(services, state.services, fn config, acc ->
        Map.delete(acc, config.service)
      end)

    # Also clean up stored versions and API list for deleted services
    new_service_versions = Map.drop(state.service_versions, deleted_names)
    new_api_list = Map.drop(state.api_list, deleted_names)

    {:noreply,
     %{
       state
       | services: new_services,
         service_versions: new_service_versions,
         api_list: new_api_list
     }}
  end

  @impl true
  def handle_call(:get_services, _from, state) do
    {:reply, state.services, state}
  end

  def handle_call({:get_api_list, service}, _from, state) do
    {:reply, Map.get(state.api_list, service), state}
  end

  def handle_call({:get_service_version, service}, _from, state) do
    {:reply, Map.get(state.service_versions, service), state}
  end

  def handle_call(:get_all_versions, _from, state) do
    {:reply, state.service_versions, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: :ok,
       services: state.services,
       api_list: state.api_list,
       service_versions: state.service_versions,
       failure_count: state.failure_count
     }, state}
  end

  @impl true
  def handle_info(:pull, state) do
    {:noreply, start_pull(state, false)}
  end

  @impl true
  def handle_info({:pull_result, ref, result}, state) do
    if state.pull_ref == ref do
      Process.demonitor(ref, [:flush])

      new_state =
        %{state | pulling?: false, pull_ref: nil}
        |> apply_pull_result(result)
        |> maybe_run_pending_pull()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.pull_ref == ref and reason != :normal do
      Logger.error(
        LogContext.line(
          "ConfigPuller",
          :pull_crashed,
          "pull process crashed",
          failure_count: state.failure_count + 1,
          reason: reason
        )
      )

      new_state =
        %{state | pulling?: false, pull_ref: nil}
        |> apply_pull_result({state.api_list, state.service_versions, false})
        |> maybe_run_pending_pull()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup_sticky, state) do
    Logger.debug(fn -> LogContext.event("ConfigPuller", :sticky_cleanup, node: node()) end)
    PhoenixGenApi.NodeSelector.cleanup_sticky_table()
    Process.send_after(self(), :cleanup_sticky, 3_600_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ### Private Functions

  # Pulls run in a separate process so status/configuration queries keep being
  # served while a slow pull is in flight.
  defp start_pull(%{pulling?: true} = state, _force?) do
    Logger.debug(fn -> LogContext.event("ConfigPuller", :pull_already_running, node: node()) end)
    %{state | pull_pending?: true}
  end

  defp start_pull(state, force?) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      result =
        try do
          pull_and_update_cache(state.services, state.api_list, state.service_versions, force?)
        rescue
          error -> {state.api_list, state.service_versions, false, Exception.message(error)}
        catch
          kind, reason -> {state.api_list, state.service_versions, false, {kind, reason}}
        end

      send(parent, {:pull_result, ref, result})
    end)

    %{state | pulling?: true, pull_ref: ref}
  end

  defp maybe_run_pending_pull(%{pull_pending?: true} = state) do
    start_pull(%{state | pull_pending?: false}, false)
  end

  defp maybe_run_pending_pull(state), do: state

  defp apply_pull_result(state, result) do
    new_state =
      case result do
        {new_api_list, new_service_versions, success?} ->
          apply_pull_success(state, new_api_list, new_service_versions, success?)

        {new_api_list, new_service_versions, _success?, reason} ->
          Logger.error(
            LogContext.line(
              "ConfigPuller",
              :pull_failed,
              "pull process failed",
              failure_count: state.failure_count + 1,
              reason: inspect(reason)
            )
          )

          %{
            state
            | api_list: new_api_list,
              service_versions: new_service_versions,
              failure_count: state.failure_count + 1
          }
      end

    schedule_pull(new_state)
    new_state
  end

  defp apply_pull_success(state, new_api_list, new_service_versions, true) do
    if state.failure_count > 0 do
      Logger.info(
        LogContext.line(
          "ConfigPuller",
          :pull_recovered,
          "pull recovered",
          failure_count: state.failure_count
        )
      )
    end

    %{
      state
      | api_list: new_api_list,
        service_versions: new_service_versions,
        failure_count: 0
    }
  end

  defp apply_pull_success(state, new_api_list, new_service_versions, false) do
    new_failure_count = state.failure_count + 1

    Logger.warning(
      LogContext.line(
        "ConfigPuller",
        :pull_failed,
        "pull failed",
        failure_count: new_failure_count,
        services: Map.keys(state.services)
      )
    )

    if new_failure_count == 1 do
      Logger.warning(
        LogContext.line(
          "ConfigPuller",
          :initial_pull_failed,
          "initial pull failed — will retry per pull_interval",
          hint: "check that service nodes are reachable and the config function is available"
        )
      )
    end

    %{
      state
      | api_list: new_api_list,
        service_versions: new_service_versions,
        failure_count: new_failure_count
    }
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

        Logger.debug(fn ->
          LogContext.line(
            "ConfigPuller",
            :services_loaded,
            "loaded services from config",
            services: Map.keys(services)
          )
        end)

        %{state | services: services}

      :error ->
        Logger.warning(
          LogContext.event("ConfigPuller", :service_configs_missing,
            message: ":service_configs not found in application config"
          )
        )

        state
    end
  end

  # Pulls all services in parallel using Task.async_stream.
  #
  # Each service is processed in its own Task, which includes:
  #   1. A version check (if configured) to decide whether to skip the pull
  #   2. A full config pull if the version has changed or version checking is disabled
  #
  # The outer timeout is pull_timeout() + 1_000 to give the inner RPC call a
  # chance to hit its own deadline first, keeping error messages meaningful.
  #
  # Returns `{new_api_list, new_service_versions, success?}` where `success?` is
  # `true` only when every service either succeeded or was skipped due to matching
  # version.
  defp pull_and_update_cache(services, api_list, service_versions, _force?)
       when map_size(services) == 0 do
    {api_list, service_versions, true}
  end

  defp pull_and_update_cache(services, api_list, service_versions, _force?) do
    task_timeout = pull_timeout() + 1_000

    {new_api_list, new_service_versions, results} =
      services
      |> Map.values()
      |> Task.async_stream(
        fn service ->
          stored_version = Map.get(service_versions, service.service)

          :telemetry.execute(
            [:phoenix_gen_api, :config, :pull, :start],
            %{system_time: System.system_time()},
            %{service: service.service}
          )

          start_time = System.monotonic_time(:microsecond)

          result = fetch_and_process_service(service, stored_version)

          duration = System.monotonic_time(:microsecond) - start_time

          {count, new_version} =
            case result do
              {:ok, fun_list, version} -> {length(fun_list), version}
              {:skipped, version} -> {0, version}
              _ -> {0, nil}
            end

          :telemetry.execute(
            [:phoenix_gen_api, :config, :pull, :stop],
            %{duration_us: duration, count: count},
            %{service: service.service, version: new_version}
          )

          {service.service, result}
        end,
        timeout: task_timeout,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce({api_list, service_versions, []}, fn
        {:ok, {service_name, {:ok, fun_list, new_version}}},
        {acc_list, acc_versions, results_acc} ->
          new_acc_versions = Map.put(acc_versions, service_name, new_version)

          {Map.put(acc_list, service_name, fun_list), new_acc_versions, [:ok | results_acc]}

        {:ok, {service_name, {:skipped, version}}}, {acc_list, acc_versions, results_acc} ->
          # Version matched — keep the existing API list entry and update the stored version
          new_acc_versions = Map.put(acc_versions, service_name, version)

          {acc_list, new_acc_versions, [:ok | results_acc]}

        {:ok, {service_name, {:error, reason}}}, {acc_list, acc_versions, results_acc} ->
          Logger.error(
            LogContext.line(
              "ConfigPuller",
              :service_pull_failed,
              "pull failed",
              service: LogContext.value(service_name),
              reason: reason
            )
          )

          :telemetry.execute(
            [:phoenix_gen_api, :config, :pull, :error],
            %{},
            %{
              service: service_name,
              failure_class: PhoenixGenApi.Errors.Classify.classify(:error, reason),
              reason: reason
            }
          )

          {acc_list, acc_versions, [{:error, reason} | results_acc]}

        {:exit, reason}, {acc_list, acc_versions, results_acc} ->
          Logger.error(
            LogContext.line(
              "ConfigPuller",
              :pull_task_exited,
              "task exited during pull",
              node: node(),
              reason: reason
            )
          )

          {acc_list, acc_versions, [{:error, {:task_exit, reason}} | results_acc]}
      end)

    # Treat partial success as success — log failed services but don't
    # increment failure_count for transient per-service errors.
    results_list =
      Enum.map(results, fn
        {:ok, _} -> :ok
        {:error, _} -> :error
        :ok -> :ok
      end)

    _success? = Enum.all?(results_list, &(&1 == :ok))

    failed_count = Enum.count(results_list, &(&1 == :error))

    if failed_count > 0 do
      Logger.warning(
        LogContext.line(
          "ConfigPuller",
          :partial_pull,
          "partial pull",
          failed_count: failed_count,
          total_count: length(results_list)
        )
      )
    end

    # Success only when every service succeeded or was legitimately skipped.
    partial_success? = failed_count == 0

    {new_api_list, new_service_versions, partial_success?}
  end

  # Fetches and processes a single service's configuration.
  #
  # When version checking is enabled for the service, this function first calls
  # the lightweight version check RPC. If the returned version matches the stored
  # version, the full pull is skipped entirely.
  #
  # Returns:
  #   - `{:ok, fun_list, new_version}` when the full pull succeeds
  #   - `{:skipped, version}` when the version matches and the pull is skipped
  #   - `{:error, reason}` when the pull fails
  defp fetch_and_process_service(service, stored_version) do
    nodes = resolve_nodes(service.nodes)

    if nodes == [] do
      Logger.error(
        LogContext.line(
          "ConfigPuller",
          :no_valid_nodes,
          "no valid nodes for service",
          service: LogContext.value(service.service),
          node: :none,
          version: LogContext.value(stored_version)
        )
      )

      {:error, :no_valid_nodes}
    else
      maybe_skip_pull(service, nodes, stored_version)
    end
  rescue
    error ->
      Logger.error(
        LogContext.line(
          "ConfigPuller",
          :rpc_call_failed,
          "RPC call failed",
          service: LogContext.value(service.service),
          node: :none,
          version: LogContext.value(stored_version),
          error: Exception.message(error)
        )
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    kind, value ->
      Logger.error(
        LogContext.line(
          "ConfigPuller",
          :unexpected_error,
          "unexpected error",
          service: LogContext.value(service.service),
          version: LogContext.value(stored_version),
          kind: kind,
          value: value
        )
      )

      {:error, {kind, value}}
  end

  # Decides whether to skip the full pull based on the version check result.
  #
  # When version checking is enabled and the remote version matches the stored
  # version, returns `{:skipped, version}` without making the full config RPC.
  #
  # When version checking is disabled, the version check fails, or the version
  # has changed, proceeds with the full pull.
  defp maybe_skip_pull(service, nodes, stored_version) do
    if ServiceConfig.version_check_enabled?(service) do
      case execute_version_check_with_fallback(nodes, service) do
        {:ok, version} when version == stored_version ->
          Logger.debug(fn ->
            LogContext.line(
              "ConfigPuller",
              :version_match,
              "version match, skipping pull",
              service: LogContext.value(service.service),
              version: version
            )
          end)

          {:skipped, version}

        {:ok, version} ->
          Logger.info(
            LogContext.line(
              "ConfigPuller",
              :version_changed,
              "version changed, performing full pull",
              service: LogContext.value(service.service),
              version: version,
              stored_version: stored_version
            )
          )

          do_full_pull(service, nodes, version)

        {:error, reason} ->
          Logger.warning(
            LogContext.line(
              "ConfigPuller",
              :version_check_failed,
              "version check failed, falling back to full pull",
              service: LogContext.value(service.service),
              reason: reason
            )
          )

          # Fall back to full pull, keeping the existing stored version
          do_full_pull(service, nodes, stored_version)
      end
    else
      # Version checking not configured — always pull, version stays nil
      do_full_pull(service, nodes, nil)
    end
  end

  # Performs the full config pull for a service and processes the results.
  defp do_full_pull(service, nodes, version) do
    case execute_rpc_with_fallback(nodes, service) do
      {:ok, fun_list} ->
        {:ok, fun_list, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Calls the version check function on remote nodes with fallback.
  #
  # Tries each node in order until one returns a successful result.
  # Returns `{:ok, version}` on success or `{:error, reason}` if all nodes fail.
  defp execute_version_check_with_fallback([node | remaining_nodes], service) do
    timeout = pull_timeout()
    version_args = service.version_args || []

    case :rpc.call(node, service.version_module, service.version_function, version_args, timeout) do
      {:badrpc, reason} ->
        Logger.warning(
          LogContext.line(
            "ConfigPuller",
            :version_check_rpc_failed,
            "version check RPC failed",
            service: LogContext.value(service.service),
            node: node,
            reason: reason
          )
        )

        if remaining_nodes == [] do
          {:error, {:badrpc, reason}}
        else
          execute_version_check_with_fallback(remaining_nodes, service)
        end

      result when is_binary(result) or is_atom(result) or is_integer(result) ->
        {:ok, result}

      other ->
        Logger.warning(
          LogContext.line(
            "ConfigPuller",
            :unexpected_version,
            "version check returned a non-scalar value",
            service: LogContext.value(service.service),
            reason: inspect(other)
          )
        )

        {:error, {:unexpected_version, other}}
    end
  end

  defp execute_version_check_with_fallback([], _service) do
    {:error, :no_nodes_available}
  end

  defp execute_rpc_with_fallback([node | remaining_nodes], service) do
    timeout = pull_timeout()

    case :rpc.call(node, service.module, service.function, service.args, timeout) do
      {:ok, fun_list} when is_list(fun_list) ->
        case process_fun_list(service.service, fun_list, node, timeout) do
          {:ok, request_types} ->
            {:ok, request_types}

          {:error, reason} ->
            if remaining_nodes == [] do
              {:error, reason}
            else
              execute_rpc_with_fallback(remaining_nodes, service)
            end
        end

      {:badrpc, reason} ->
        Logger.warning(
          LogContext.line(
            "ConfigPuller",
            :rpc_failed,
            "RPC failed",
            service: LogContext.value(service.service),
            node: node,
            reason: reason
          )
        )

        if remaining_nodes == [] do
          {:error, {:badrpc, reason}}
        else
          execute_rpc_with_fallback(remaining_nodes, service)
        end

      other ->
        Logger.error(
          LogContext.line(
            "ConfigPuller",
            :unexpected_rpc_result,
            "unexpected RPC result",
            service: LogContext.value(service.service),
            node: node,
            result: LogContext.payload(other)
          )
        )

        if remaining_nodes == [] do
          {:error, {:unexpected_result, other}}
        else
          execute_rpc_with_fallback(remaining_nodes, service)
        end
    end
  end

  defp execute_rpc_with_fallback([], _service) do
    {:error, :no_nodes_available}
  end

  defp resolve_nodes({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    result = apply(module, function, args)

    case result do
      nodes when is_list(nodes) ->
        Enum.filter(nodes, &is_atom/1)

      _ ->
        Logger.error(
          LogContext.line(
            "ConfigPuller",
            :invalid_node_list,
            "invalid node list from MFA",
            result_type: LogContext.type_name(result)
          )
        )

        []
    end
  rescue
    error ->
      Logger.error(
        LogContext.line(
          "ConfigPuller",
          :node_resolution_failed,
          "failed to resolve nodes",
          error: Exception.message(error)
        )
      )

      []
  end

  defp resolve_nodes(nodes) when is_list(nodes) do
    Enum.filter(nodes, &is_atom/1)
  end

  defp resolve_nodes(other) do
    Logger.error(
      LogContext.line(
        "ConfigPuller",
        :invalid_nodes_configuration,
        "invalid nodes configuration",
        config_type: LogContext.type_name(other)
      )
    )

    []
  end

  # Processes the raw fun_list returned by a single RPC call.
  #
  # Phase 1 – prepare: sanitise and validate each item on this process (CPU work,
  # no I/O bottleneck). Items that fail any check are logged and dropped.
  #
  # Phase 2 – commit: call ConfigDb.batch_add/1 once with all valid configs.
  # This is a single direct ETS write (no GenServer round-trip per item) instead
  # of the previous N individual GenServer.call(:add) invocations.
  defp process_fun_list(service_name, fun_list, node, timeout) do
    valid_configs =
      Enum.flat_map(fun_list, &validate_fun_config(&1, service_name, node, timeout))

    cond do
      valid_configs == [] ->
        Logger.warning(
          LogContext.line(
            "ConfigPuller",
            :no_valid_configs,
            "no valid configs to insert",
            service: LogContext.value(service_name)
          )
        )

        {:error, :no_valid_configs}

      true ->
        case ConfigDb.batch_add(valid_configs) do
          {:ok, count} when count > 0 ->
            request_types = Enum.map(valid_configs, & &1.request_type)

            Logger.info(
              LogContext.line(
                "ConfigPuller",
                :batch_inserted,
                "batch inserted",
                service: LogContext.value(service_name),
                node: LogContext.value(node),
                count: count,
                request_types: request_types
              )
            )

            {:ok, request_types}

          other ->
            Logger.error(
              LogContext.line(
                "ConfigPuller",
                :batch_add_failed,
                "batch_add failed",
                service: LogContext.value(service_name),
                reason: inspect(other)
              )
            )

            {:error, :no_configs_stored}
        end
    end
  end

  defp validate_fun_config(config = %FunConfig{}, service_name, node, timeout) do
    config =
      config
      |> enforce_service_name(service_name)
      |> ensure_version()

    case validate_mfa_safety(config.mfa, node, timeout) do
      :ok -> keep_valid_config(config, service_name, node)
      {:error, reason} -> reject_unsafe_config(config, service_name, node, reason)
    end
  end

  defp validate_fun_config(other, service_name, node, _timeout) do
    Logger.error(
      LogContext.line(
        "ConfigPuller",
        :unexpected_fun_list_item,
        "unexpected item in fun_list",
        service: LogContext.value(service_name),
        node: node,
        item_type: LogContext.type_name(other)
      )
    )

    []
  end

  defp keep_valid_config(config, service_name, node) do
    if FunConfig.valid?(config) do
      [config]
    else
      reject_invalid_config(config, service_name, node)
    end
  end

  defp reject_invalid_config(config, service_name, node) do
    Logger.warning(
      LogContext.line(
        "ConfigPuller",
        :invalid_config,
        "invalid config, skipping",
        service: LogContext.value(service_name),
        node: node,
        request_type: LogContext.value(config.request_type),
        version: LogContext.value(FunConfig.version(config))
      )
    )

    PhoenixGenApi.ConfigFailed.record(config, validation_reasons(config), :pull, node)
    []
  end

  defp validation_reasons(config) do
    case FunConfig.validate_with_details(config) do
      {:error, errors} -> errors
      _ -> ["unknown validation error"]
    end
  end

  defp reject_unsafe_config(config, service_name, node, reason) do
    Logger.error(
      LogContext.line(
        "ConfigPuller",
        :unsafe_mfa,
        "unsafe MFA, skipping",
        service: LogContext.value(service_name),
        node: node,
        request_type: LogContext.value(config.request_type),
        version: LogContext.value(FunConfig.version(config)),
        reason: reason
      )
    )

    PhoenixGenApi.ConfigFailed.record(config, to_string(reason), :pull, node)
    []
  end

  defp enforce_service_name(config = %FunConfig{}, service_name) do
    Shared.enforce_service_name(config, service_name)
  end

  defp ensure_version(config = %FunConfig{}) do
    Shared.ensure_version(config)
  end

  defp validate_mfa_safety({mod, fun, _args}, node, timeout)
       when is_atom(mod) and is_atom(fun) and is_atom(node) do
    case :rpc.call(node, Code, :ensure_loaded?, [mod], timeout) do
      true ->
        :ok

      false ->
        {:error, "module #{inspect(mod)} not loaded on node #{inspect(node)}"}

      {:badrpc, reason} ->
        # SECURITY: Reject config when we can't verify the module exists.
        # Previously this returned :ok (allowing unverified configs), which
        # was a security vulnerability — a disconnected or malicious node
        # could register arbitrary MFAs that might not actually exist.
        Logger.warning(
          LogContext.line(
            "ConfigPuller",
            :module_verification_failed,
            "failed to verify module, rejecting config for safety",
            node: node,
            module: mod,
            reason: reason
          )
        )

        {:error,
         "cannot verify module #{inspect(mod)} on node #{inspect(node)}: #{inspect(reason)}"}
    end
  end

  defp validate_mfa_safety({mod, fun, _args}, _node, _timeout)
       when is_atom(mod) and is_atom(fun) do
    if Code.ensure_loaded?(mod) do
      :ok
    else
      {:error, "module #{inspect(mod)} not loaded locally"}
    end
  end

  defp validate_mfa_safety(other, _node, _timeout) do
    {:error, "invalid MFA format: #{inspect(other)}"}
  end

  defp schedule_pull(state) do
    interval = calculate_pull_interval(state)

    Logger.debug(fn ->
      LogContext.event("ConfigPuller", :next_pull_scheduled, interval_ms: interval)
    end)

    Process.send_after(self(), :pull, interval)
  end

  defp calculate_pull_interval(%{failure_count: 0}), do: pull_interval()

  defp calculate_pull_interval(%{failure_count: count}) do
    base_interval = pull_interval()
    max_interval = @max_backoff_interval
    interval = min(base_interval * :math.pow(@backoff_multiplier, count), max_interval)
    round(interval)
  end

  defp pull_timeout,
    do: Application.get_env(:phoenix_gen_api, :gen_api, [])[:pull_timeout] || @default_timeout

  defp pull_interval,
    do: Application.get_env(:phoenix_gen_api, :gen_api, [])[:pull_interval] || @default_interval
end
