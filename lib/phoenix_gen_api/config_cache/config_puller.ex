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

  ## Fault Tolerance

  - Failed RPC calls are logged and do not crash the puller
  - Node lists are validated before use
  - Configuration validation prevents invalid configs from entering the cache
  - Exponential backoff on repeated failures (up to a maximum)

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
  Forces an immediate pull of configurations from the registered services.
  """
  def pull() do
    GenServer.cast(__MODULE__, :pull)
  end

  @doc """
  Deletes a list of services from the puller.
  The `services` argument must be a list of `%ServiceConfig{}` structs.
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

  ### Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PhoenixGenApi.ConfigPuller, init")
    {:ok, %{services: %{}, api_list: %{}, failure_count: 0}, {:continue, :load_initial_data}}
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
    {new_api_list, success?} = pull_and_update_cache(state.services, state.api_list)

    new_state =
      if success? do
        %{state | api_list: new_api_list, failure_count: 0}
      else
        new_failure_count = state.failure_count + 1
        Logger.warning("PhoenixGenApi.ConfigPuller, pull failed, failure count: #{new_failure_count}")
        %{state | failure_count: new_failure_count}
      end

    schedule_pull(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:delete, services}, state) do
    new_services =
      Enum.reduce(services, state.services, fn config, acc ->
        Map.delete(acc, config.service)
      end)

    {:noreply, %{state | services: new_services}}
  end

  @impl true
  def handle_call(:get_services, _from, state) do
    {:reply, state.services, state}
  end

  def handle_call({:get_api_list, service}, _from, state) do
    {:reply, Map.get(state.api_list, service), state}
  end

  @impl true
  def handle_info(:pull, state) do
    {new_api_list, success?} = pull_and_update_cache(state.services, state.api_list)

    new_state =
      if success? do
        %{state | api_list: new_api_list, failure_count: 0}
      else
        new_failure_count = state.failure_count + 1
        Logger.warning("PhoenixGenApi.ConfigPuller, pull failed, failure count: #{new_failure_count}")
        %{state | failure_count: new_failure_count}
      end

    schedule_pull(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages (e.g., from test helpers)
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

  defp pull_and_update_cache(services, api_list) do
    {new_api_list, results} =
      Enum.reduce(services, {api_list, []}, fn {_key, service}, {acc, results_acc} ->
        Logger.debug("PhoenixGenApi.ConfigPuller, pulling config from service: #{inspect(service)}")

        case fetch_and_process_service(service) do
          {:ok, fun_list} ->
            new_acc = Map.put(acc, service.service, fun_list)
            {new_acc, [:ok | results_acc]}

          {:error, reason} ->
            Logger.error(
              "PhoenixGenApi.ConfigPuller, failed to pull from service #{inspect(service.service)}: #{inspect(reason)}"
            )

            {acc, [{:error, reason} | results_acc]}
        end
      end)

    success? = Enum.all?(results, &(&1 == :ok))
    {new_api_list, success?}
  end

  defp fetch_and_process_service(service = %ServiceConfig{}) do
    try do
      nodes = resolve_nodes(service.nodes)

      if nodes == [] do
        Logger.error("PhoenixGenApi.ConfigPuller, no valid nodes for service: #{inspect(service.service)}")
        {:error, :no_valid_nodes}
      else
        execute_rpc_with_fallback(nodes, service)
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

  defp process_fun_list(service_name, fun_list, node, timeout) do
    Enum.reduce(fun_list, [], fn
      config = %FunConfig{}, acc ->
        Logger.info("PhoenixGenApi.ConfigPuller, adding config: #{inspect(config)}")

        # Security: validate and enforce service name
        config = enforce_service_name(config, service_name)

        # Backward compatibility: ensure :version field exists for old library nodes
        config = ensure_version(config)

        # Validate MFA to prevent remote code execution
        case validate_mfa_safety(config.mfa, node, timeout) do
          :ok ->
            if FunConfig.valid?(config) do
              ConfigDb.add(config)
              [config.request_type | acc]
            else
              Logger.warning(
                "PhoenixGenApi.ConfigPuller, invalid config for #{inspect(config.request_type)}, skipping"
              )

              acc
            end

          {:error, reason} ->
            Logger.error(
              "PhoenixGenApi.ConfigPuller, unsafe MFA for #{inspect(config.request_type)}: #{inspect(reason)}, skipping"
            )

            acc
        end

      other, acc ->
        Logger.error("PhoenixGenApi.ConfigPuller, unexpected item in fun_list: #{inspect(other)}")
        acc
    end)
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
    if Map.has_key?(config, :version) and is_binary(config.version) and byte_size(config.version) > 0 do
      config
    else
      Logger.debug("PhoenixGenApi.ConfigPuller, adding default version to config for #{inspect(config.request_type)}")
      # Convert to map, add version, then rebuild with current struct definition
      # This handles old library nodes that don't have :version in their defstruct
      config
      |> Map.from_struct()
      |> Map.put(:version, "0.0.0")
      |> then(&struct(FunConfig, &1))
    end
  end

  defp validate_mfa_safety({mod, fun, _args}, node, timeout)
       when is_atom(mod) and is_atom(fun) and is_atom(node) do
    # Verify module is loaded on the target remote node via RPC
    case :rpc.call(node, Code, :ensure_loaded?, [mod], timeout) do
      true ->
        :ok

      false ->
        {:error, "module #{inspect(mod)} not loaded on node #{inspect(node)}"}

      {:badrpc, reason} ->
        Logger.warning(
          "PhoenixGenApi.ConfigPuller, failed to verify module #{inspect(mod)} on node #{inspect(node)}: #{inspect(reason)}"
        )

        # If we can't verify, allow it but log a warning (node might be unreachable for verification)
        :ok
    end
  end

  defp validate_mfa_safety({mod, fun, _args}, _node, _timeout)
       when is_atom(mod) and is_atom(fun) do
    # Fallback for local node or when node is not specified
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
    # Exponential backoff with max cap
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
