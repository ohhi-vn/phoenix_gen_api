defmodule PhoenixGenApi.ConfigPusher do
  @moduledoc """
  A client-side module used on remote/service nodes to push configurations
  to the PhoenixGenApi gateway/server node.

  Unlike `ConfigReceiver` (which is a GenServer running on the server), this
  module is a simple collection of functions that make RPC calls to the server
  node. It does not maintain any state of its own.

  ## RPC Communication

  All functions use `:rpc.call/5` to communicate with the server node. If the
  server is unreachable or the RPC call fails, the result is wrapped in
  `{:error, {:badrpc, reason}}`.

  ## Typical Usage

  Remote nodes should call `push_on_startup/3` during their application start
  (e.g., in the `start/2` callback or a GenServer's `init`/`handle_continue`)
  to register their service configuration with the gateway.

  ## Example

      alias PhoenixGenApi.Structs.{FunConfig, PushConfig}
      alias PhoenixGenApi.ConfigPusher

      fun_configs = [
        %FunConfig{
          request_type: "get_data",
          service: :my_service,
          nodes: [Node.self()],
          choose_node_mode: :random,
          timeout: 5_000,
          mfa: {MyApp.Api, :get_data, []},
          arg_types: %{"id" => :string},
          response_type: :sync,
          version: "1.0.0"
        }
      ]

      push_config = ConfigPusher.from_service_config(
        :my_service,
        [Node.self()],
        fun_configs,
        config_version: "1.0.0",
        module: MyApp.GenApi.Supporter,
        function: :get_config
      )

      # Push to gateway node
      ConfigPusher.push_on_startup(:gateway@host, push_config)

      # Or verify first
      case ConfigPusher.verify(:gateway@host, :my_service, "1.0.0") do
        {:ok, :matched} -> :already_registered
        {:ok, :mismatch, _} -> ConfigPusher.push(:gateway@host, push_config)
        {:error, :not_found} -> ConfigPusher.push(:gateway@host, push_config)
      end
  """

  alias PhoenixGenApi.Structs.{PushConfig, FunConfig}

  require Logger

  @default_timeout 5_000

  ### Public API

  @doc """
  Pushes configurations to the server node.

  Makes an RPC call to `PhoenixGenApi.ConfigReceiver.push/2` on the server node.
  The server validates the `PushConfig`, checks the version, and stores the
  configs if the version is new (or if `:force` is set).

  ## Parameters

    - `server_node` - The node name (atom) of the PhoenixGenApi gateway
    - `push_config` - A `%PushConfig{}` struct
    - `opts` - Options keyword list:
      - `:timeout` - RPC timeout in ms (default: 5000)
      - `:force` - Force push even if version matches (default: false)

  ## Returns

    - `{:ok, :accepted}` - New configs were stored successfully
    - `{:ok, :skipped, reason}` - Push was skipped (e.g., version matches)
    - `{:error, term()}` - Push failed (includes `:badrpc` errors)

  ## Example

      {:ok, :accepted} = ConfigPusher.push(:gateway@host, push_config, timeout: 10_000)
      {:ok, :skipped, :version_matches} = ConfigPusher.push(:gateway@host, push_config)
      {:error, {:badrpc, :nodedown}} = ConfigPusher.push(:unreachable@host, push_config)
  """
  @spec push(node(), PushConfig.t(), keyword()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push(server_node, push_config, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    force = Keyword.get(opts, :force, false)

    Logger.info(
      "[ConfigPusher] pushing: service=#{inspect(push_config.service)} " <>
        "node=#{inspect(server_node)} timeout=#{timeout}ms force=#{force}"
    )

    # Read push_token at runtime so config changes take effect
    push_token = Application.get_env(:phoenix_gen_api, :push_token)
    push_config = %{push_config | push_token: push_token}

    result =
      :rpc.call(
        server_node,
        PhoenixGenApi.ConfigReceiver,
        :push,
        [push_config, [force: force]],
        timeout
      )

    case result do
      {:ok, :accepted} = result ->
        Logger.info(
          "[ConfigPusher] push accepted: service=#{inspect(push_config.service)} " <>
            "node=#{inspect(server_node)}"
        )

        result

      {:ok, :skipped, reason} = result ->
        Logger.warning(
          "[ConfigPusher] push skipped: service=#{inspect(push_config.service)} " <>
            "node=#{inspect(server_node)} reason=#{inspect(reason)}"
        )

        result

      {:error, reason} = error ->
        Logger.error(
          "[ConfigPusher] push failed: service=#{inspect(push_config.service)} " <>
            "node=#{inspect(server_node)} reason=#{inspect(reason)}"
        )

        error

      {:badrpc, reason} = rpc_error ->
        Logger.error(
          "[ConfigPusher] RPC call failed: node=#{inspect(server_node)} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, rpc_error}
    end
  end

  @doc """
  Pushes configurations to the server node without options.

  Convenience function that calls `push/3` with default options.

  ## Parameters

    - `server_node` - The node name (atom) of the PhoenixGenApi gateway
    - `push_config` - A `%PushConfig{}` struct

  ## Returns

  Same as `push/3`.
  """
  @spec push(node(), PushConfig.t()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push(server_node, push_config) do
    push(server_node, push_config, [])
  end

  @doc """
  Verifies that the server has the given service and config version.

  Makes an RPC call to `PhoenixGenApi.ConfigReceiver.verify/2` on the server
  node. Useful for checking whether a push is necessary before sending the
  full configuration.

  ## Parameters

    - `server_node` - The gateway node
    - `service` - Service name (string or atom)
    - `config_version` - Expected config version string
    - `opts` - Options:
      - `:timeout` - RPC timeout in ms (default: 5000)

  ## Returns

    - `{:ok, :matched}` - Server has the same version
    - `{:ok, :mismatch, stored_version}` - Server has a different version
    - `{:error, :not_found}` - Service is not known on the server
    - `{:error, {:badrpc, reason}}` - RPC call failed

  ## Example

      {:ok, :matched} = ConfigPusher.verify(:gateway@host, :my_service, "1.0.0")
      {:ok, :mismatch, "0.9.0"} = ConfigPusher.verify(:gateway@host, :my_service, "1.0.0")
      {:error, :not_found} = ConfigPusher.verify(:gateway@host, :unknown_service, "1.0.0")
  """
  @spec verify(node(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, :matched} | {:ok, :mismatch, String.t()} | {:error, term()}
  def verify(server_node, service, config_version, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.debug(
      "[ConfigPusher] verifying: service=#{inspect(service)} " <>
        "version=#{inspect(config_version)} node=#{inspect(server_node)}"
    )

    result =
      :rpc.call(
        server_node,
        PhoenixGenApi.ConfigReceiver,
        :verify,
        [service, config_version],
        timeout
      )

    case result do
      {:ok, :matched} ->
        Logger.debug(
          "[ConfigPusher] verify matched: service=#{inspect(service)} " <>
            "version=#{inspect(config_version)} node=#{inspect(server_node)}"
        )

        {:ok, :matched}

      {:ok, :mismatch, stored_version} ->
        Logger.debug(
          "[ConfigPusher] verify mismatch: service=#{inspect(service)} " <>
            "node=#{inspect(server_node)} expected=#{inspect(config_version)} " <>
            "stored=#{inspect(stored_version)}"
        )

        {:ok, :mismatch, stored_version}

      {:error, :not_found} ->
        Logger.debug(
          "[ConfigPusher] verify not found: service=#{inspect(service)} " <>
            "node=#{inspect(server_node)}"
        )

        {:error, :not_found}

      {:error, reason} ->
        Logger.error(
          "[ConfigPusher] verify failed: service=#{inspect(service)} " <>
            "node=#{inspect(server_node)} reason=#{inspect(reason)}"
        )

        {:error, reason}

      {:badrpc, reason} ->
        Logger.error(
          "[ConfigPusher] RPC verify call failed: node=#{inspect(server_node)} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, {:badrpc, reason}}
    end
  end

  @doc """
  Verifies that the server has the given service and config version without options.

  Convenience function that calls `verify/4` with default options.

  ## Parameters

    - `server_node` - The gateway node
    - `service` - Service name (string or atom)
    - `config_version` - Expected config version string

  ## Returns

  Same as `verify/4`.
  """
  @spec verify(node(), String.t() | atom(), String.t()) ::
          {:ok, :matched} | {:ok, :mismatch, String.t()} | {:error, term()}
  def verify(server_node, service, config_version) do
    verify(server_node, service, config_version, [])
  end

  @doc """
  Pushes configs and handles the "push once on startup" pattern.

  This is the main entry point for remote nodes. It behaves the same as
  `push/3` but logs the result at info level with more prominent messaging,
  making it easy to see in startup logs whether the configuration was
  successfully registered.

  Call this function in your application's `start/2` callback or a GenServer's
  `handle_continue/2` to ensure your service is registered with the gateway
  on startup.

  ## Parameters

    - `server_node` - The node name (atom) of the PhoenixGenApi gateway
    - `push_config` - A `%PushConfig{}` struct
    - `opts` - Options keyword list (same as `push/3`):
      - `:timeout` - RPC timeout in ms (default: 5000)
      - `:force` - Force push even if version matches (default: false)

  ## Returns

  Same as `push/3`.

  ## Example

      # In your application.ex
      def start(_type, _args) do
        # ... start your supervision tree, then:
        ConfigPusher.push_on_startup(:gateway@host, push_config)
        # ...
      end

      # Or in a GenServer
      def init(opts) do
        {:ok, initial_state, {:continue, :register_config}}
      end

      def handle_continue(:register_config, state) do
        ConfigPusher.push_on_startup(:gateway@host, push_config)
        {:noreply, state}
      end
  """
  @spec push_on_startup(node(), PushConfig.t(), keyword()) ::
          {:ok, :accepted} | {:ok, :skipped, term()} | {:error, term()}
  def push_on_startup(server_node, push_config, opts) do
    service = push_config.service
    version = push_config.config_version

    Logger.info(
      "[ConfigPusher] startup push: service=#{inspect(service)} " <>
        "version=#{inspect(version)} node=#{inspect(server_node)}"
    )

    result = push(server_node, push_config, opts)

    case result do
      {:ok, :accepted} ->
        Logger.info(
          "[ConfigPusher] startup push accepted: " <>
            "service=#{inspect(service)} version=#{inspect(version)} " <>
            "node=#{inspect(server_node)}"
        )

      {:ok, :skipped, reason} ->
        Logger.info(
          "[ConfigPusher] startup push skipped: " <>
            "service=#{inspect(service)} version=#{inspect(version)} " <>
            "node=#{inspect(server_node)} reason=#{inspect(reason)}"
        )

      {:error, reason} ->
        Logger.error(
          "[ConfigPusher] startup push failed: " <>
            "service=#{inspect(service)} version=#{inspect(version)} " <>
            "node=#{inspect(server_node)} reason=#{inspect(reason)}"
        )
    end

    result
  end

  @doc """
  Helper to create a `PushConfig` from existing service configuration data.

  This is a convenience function that builds a `%PushConfig{}` struct from the
  individual components, handling the optional fields for auto-pull and version
  checking.

  ## Parameters

    - `service` - Service name (string or atom)
    - `nodes` - List of node names (atoms or strings)
    - `fun_configs` - List of `FunConfig` structs
    - `opts` - Options keyword list:
      - `:config_version` - Config version string (**required**)
      - `:module` - Module for auto-pull (optional)
      - `:function` - Function for auto-pull (optional)
      - `:args` - Args for auto-pull (default: `[]`)
      - `:version_module` - Version check module (optional)
      - `:version_function` - Version check function (optional)
      - `:version_args` - Version check args (default: `[]`)

  ## Returns

  A `%PushConfig{}` struct.

  ## Raises

  Raises `ArgumentError` if `:config_version` is not provided in `opts`.

  ## Example

      push_config = ConfigPusher.from_service_config(
        :my_service,
        [Node.self()],
        fun_configs,
        config_version: "1.0.0",
        module: MyApp.GenApi.Supporter,
        function: :get_config,
        version_module: MyApp.GenApi.Supporter,
        version_function: :get_config_version
      )
  """
  @spec from_service_config(
          String.t() | atom(),
          [atom() | String.t()],
          [FunConfig.t()],
          keyword()
        ) ::
          PushConfig.t()
  def from_service_config(service, nodes, fun_configs, opts) do
    config_version = Keyword.get(opts, :config_version)

    if is_nil(config_version) or (is_binary(config_version) and byte_size(config_version) == 0) do
      raise ArgumentError,
            "PhoenixGenApi.ConfigPusher.from_service_config requires a :config_version option"
    end

    module = Keyword.get(opts, :module)
    function = Keyword.get(opts, :function)
    args = Keyword.get(opts, :args, [])
    version_module = Keyword.get(opts, :version_module)
    version_function = Keyword.get(opts, :version_function)
    version_args = Keyword.get(opts, :version_args, [])

    %PushConfig{
      service: service,
      nodes: nodes,
      config_version: config_version,
      fun_configs: fun_configs,
      module: module,
      function: function,
      args: args,
      version_module: version_module,
      version_function: version_function,
      version_args: version_args,
      push_token: nil
    }
  end
end
