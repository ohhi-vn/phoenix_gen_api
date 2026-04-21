defmodule PhoenixGenApi.ConfigPuller do
  @moduledoc """
  This module is responsible for periodically pulling function configurations (`%FunConfig{}`)
  from remote nodes and updating the `ConfigDb`.

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

  ## Security

  - Validates that remote configs match the expected service name
  - Validates FunConfig structs before adding to cache
  - Rejects configs with invalid MFAs or node configurations
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.{ServiceConfig, FunConfig}

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
  Triggers an immediate pull of configurations from the registered services.
  Version checking is respected — if the stored version matches the remote version,
  the full pull for that service is skipped.
  """
  def pull() do
    GenServer.cast(__MODULE__, :pull)
  end

  @doc """
  Forces an immediate full pull of configurations from all registered services,
  ignoring version checking. This clears all stored versions first, so every
  service will be re-fetched regardless of whether its version has changed.

  Use this when you want to guarantee a fresh configuration pull, for example
  after a deployment or when you suspect the local cache is stale.
  """
  def force_pull() do
    GenServer.cast(__MODULE__, :force_pull)
  end

  @doc """
  Deletes a list of services from the puller.
  The `services` argument must be a list of `%ServiceConfig{}` structs.

  Deleting a service also removes its stored version and API list entry.
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
  def get_all_versions() do
    GenServer.call(__MODULE__, :get_all_versions)
  end

  ### Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PhoenixGenApi.ConfigPuller, init")

    state = %{
      services: %{},
      api_list: %{},
      service_versions: %{},
      failure_count: 0
    }

    {:ok, state, {:continue, :load_initial_data}}
  end

  @impl true
  def handle_continue(:load_initial_data, state) do
    Logger.debug("PhoenixGenApi.ConfigPuller, loading initial data")
    new_state = load_services_from_config(state)
    Process.send_after(self(), :pull, 1_000)
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
    {new_api_list, new_service_versions, success?} =
      pull_and_update_cache(state.services, state.api_list, state.service_versions, false)

    new_state =
      if success? do
        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: 0
        }
      else
        new_failure_count = state.failure_count + 1

        Logger.warning(
          "PhoenixGenApi.ConfigPuller, pull failed, failure count: #{new_failure_count}"
        )

        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: new_failure_count
        }
      end

    schedule_pull(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:force_pull, state) do
    # Clear all stored versions so that version checks will always fail,
    # forcing a full pull for all services regardless of version changes.
    cleared_versions = %{}

    {new_api_list, new_service_versions, success?} =
      pull_and_update_cache(state.services, state.api_list, cleared_versions, false)

    new_state =
      if success? do
        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: 0
        }
      else
        new_failure_count = state.failure_count + 1

        Logger.warning(
          "PhoenixGenApi.ConfigPuller, force_pull failed, failure count: #{new_failure_count}"
        )

        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: new_failure_count
        }
      end

    schedule_pull(new_state)
    {:noreply, new_state}
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

  @impl true
  def handle_info(:pull, state) do
    {new_api_list, new_service_versions, success?} =
      pull_and_update_cache(state.services, state.api_list, state.service_versions, false)

    new_state =
      if success? do
        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: 0
        }
      else
        new_failure_count = state.failure_count + 1

        Logger.warning(
          "PhoenixGenApi.ConfigPuller, pull failed, failure count: #{new_failure_count}"
        )

        %{
          state
          | api_list: new_api_list,
            service_versions: new_service_versions,
            failure_count: new_failure_count
        }
      end

    schedule_pull(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
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
            "PhoenixGenApi.ConfigPuller, failed to pull from service #{inspect(service_name)}: #{inspect(reason)}"
          )

          {acc_list, acc_versions, [{:error, reason} | results_acc]}

        {:exit, reason}, {acc_list, acc_versions, results_acc} ->
          Logger.error("PhoenixGenApi.ConfigPuller, task exited during pull: #{inspect(reason)}")
          {acc_list, acc_versions, [{:error, {:task_exit, reason}} | results_acc]}
      end)

    success? = Enum.all?(results, &(&1 == :ok))
    {new_api_list, new_service_versions, success?}
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
    try do
      nodes = resolve_nodes(service.nodes)

      if nodes == [] do
        Logger.error(
          "PhoenixGenApi.ConfigPuller, no valid nodes for service: #{inspect(service.service)}"
        )

        {:error, :no_valid_nodes}
      else
        maybe_skip_pull(service, nodes, stored_version)
      end
    rescue
      error ->
        Logger.error(
          "PhoenixGenApi.ConfigPuller, RPC call failed for #{inspect(service.service)}: #{Exception.message(error)}"
        )

        {:error, {:exception, Exception.message(error)}}
    catch
      kind, value ->
        Logger.error(
          "PhoenixGenApi.ConfigPuller, unexpected error for #{inspect(service.service)}: #{kind}: #{inspect(value)}"
        )

        {:error, {kind, value}}
    end
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
          Logger.debug(
            "PhoenixGenApi.ConfigPuller, version match for " <>
              "#{inspect(service.service)} (version: #{inspect(version)}), skipping pull"
          )

          {:skipped, version}

        {:ok, version} ->
          Logger.info(
            "PhoenixGenApi.ConfigPuller, version changed for " <>
              "#{inspect(service.service)}, stored: #{inspect(stored_version)}, " <>
              "new: #{inspect(version)}, performing full pull"
          )

          do_full_pull(service, nodes, version)

        {:error, reason} ->
          Logger.warning(
            "PhoenixGenApi.ConfigPuller, version check failed for " <>
              "#{inspect(service.service)}: #{inspect(reason)}, falling back to full pull"
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
          "PhoenixGenApi.ConfigPuller, version check RPC failed on node " <>
            "#{inspect(node)} for #{inspect(service.service)}: #{inspect(reason)}"
        )

        if remaining_nodes == [] do
          {:error, {:badrpc, reason}}
        else
          execute_version_check_with_fallback(remaining_nodes, service)
        end

      result ->
        {:ok, result}
    end
  end

  defp execute_version_check_with_fallback([], _service) do
    {:error, :no_nodes_available}
  end

  defp execute_rpc_with_fallback([node | remaining_nodes], service) do
    timeout = pull_timeout()

    case :rpc.call(node, service.module, service.function, service.args, timeout) do
      {:ok, fun_list} when is_list(fun_list) ->
        {:ok, process_fun_list(service.service, fun_list, node, timeout)}

      {:badrpc, reason} ->
        Logger.warning(
          "PhoenixGenApi.ConfigPuller, RPC failed on node #{inspect(node)} for #{inspect(service.service)}: #{inspect(reason)}"
        )

        if remaining_nodes == [] do
          {:error, {:badrpc, reason}}
        else
          execute_rpc_with_fallback(remaining_nodes, service)
        end

      other ->
        Logger.error(
          "PhoenixGenApi.ConfigPuller, unexpected RPC result from #{inspect(node)}: #{inspect(other)}"
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
    try do
      result = apply(module, function, args)

      case result do
        nodes when is_list(nodes) ->
          Enum.filter(nodes, &is_atom/1)

        _ ->
          Logger.error(
            "PhoenixGenApi.ConfigPuller, invalid node list from MFA: #{inspect(result)}"
          )

          []
      end
    rescue
      error ->
        Logger.error(
          "PhoenixGenApi.ConfigPuller, failed to resolve nodes: #{Exception.message(error)}"
        )

        []
    end
  end

  defp resolve_nodes(nodes) when is_list(nodes) do
    Enum.filter(nodes, &is_atom/1)
  end

  defp resolve_nodes(other) do
    Logger.error("PhoenixGenApi.ConfigPuller, invalid nodes configuration: #{inspect(other)}")
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
      Enum.flat_map(fun_list, fn
        config = %FunConfig{} ->
          config =
            config
            |> enforce_service_name(service_name)
            |> ensure_version()

          case validate_mfa_safety(config.mfa, node, timeout) do
            :ok ->
              if FunConfig.valid?(config) do
                [config]
              else
                Logger.warning(
                  "PhoenixGenApi.ConfigPuller, invalid config for #{inspect(config.request_type)}, skipping"
                )

                []
              end

            {:error, reason} ->
              Logger.error(
                "PhoenixGenApi.ConfigPuller, unsafe MFA for #{inspect(config.request_type)}: #{inspect(reason)}, skipping"
              )

              []
          end

        other ->
          Logger.error(
            "PhoenixGenApi.ConfigPuller, unexpected item in fun_list: #{inspect(other)}"
          )

          []
      end)

    case valid_configs do
      [] ->
        Logger.warning(
          "PhoenixGenApi.ConfigPuller, no valid configs to insert for service #{inspect(service_name)}"
        )

      _ ->
        case ConfigDb.batch_add(valid_configs) do
          {:ok, count} ->
            Logger.info(
              "PhoenixGenApi.ConfigPuller, batch inserted #{count} configs for service #{inspect(service_name)}"
            )

          {:error, :all_invalid} ->
            Logger.error(
              "PhoenixGenApi.ConfigPuller, batch_add reported all configs invalid for service #{inspect(service_name)}"
            )
        end
    end

    Enum.map(valid_configs, & &1.request_type)
  end

  defp enforce_service_name(config = %FunConfig{}, service_name) do
    if config.service == service_name do
      config
    else
      Logger.warning(
        "PhoenixGenApi.ConfigPuller, service_name mismatch in FunConfig #{inspect(config.request_type)}, expected #{inspect(service_name)}, got #{inspect(config.service)}, overwriting"
      )

      %FunConfig{config | service: service_name}
    end
  end

  defp ensure_version(config = %FunConfig{}) do
    if Map.has_key?(config, :version) and is_binary(config.version) and
         byte_size(config.version) > 0 do
      config
    else
      Logger.debug(
        "PhoenixGenApi.ConfigPuller, adding default version to config for #{inspect(config.request_type)}"
      )

      config
      |> Map.from_struct()
      |> Map.put(:version, "0.0.0")
      |> then(&struct(FunConfig, &1))
    end
  end

  defp validate_mfa_safety({mod, fun, _args}, node, timeout)
       when is_atom(mod) and is_atom(fun) and is_atom(node) do
    case :rpc.call(node, Code, :ensure_loaded?, [mod], timeout) do
      true ->
        :ok

      false ->
        {:error, "module #{inspect(mod)} not loaded on node #{inspect(node)}"}

      {:badrpc, reason} ->
        Logger.warning(
          "PhoenixGenApi.ConfigPuller, failed to verify module #{inspect(mod)} on node #{inspect(node)}: #{inspect(reason)}"
        )

        :ok
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
    Logger.debug("PhoenixGenApi.ConfigPuller, scheduling next pull in #{interval}ms")
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
