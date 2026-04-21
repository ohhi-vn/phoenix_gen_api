defmodule PhoenixGenApi.Structs.FunConfig do
  @moduledoc """
  Defines the configuration for a function that can be called through the API.

  This struct holds all the necessary information to route, validate, and execute
  a function call based on an incoming request.

  ## Retry

  The `retry` field configures retry behavior when request execution fails
  (returns `{:error, _}` or `{:error, _, _}`).

  Possible values:

  - `nil` - No retry (default, backward compatible)
  - A positive number (e.g., `3`) - Equivalent to `{:all_nodes, 3}`.
    Retry across all available nodes.
  - `{:same_node, positive_number}` (e.g., `{:same_node, 2}`) - Retry on the
    same node(s) that were originally selected by the `choose_node_mode` strategy.
    Useful when the failure might be transient.
  - `{:all_nodes, positive_number}` (e.g., `{:all_nodes, 3}`) - Retry across
    all available nodes in the cluster. Useful when a node might be down.

  For `nodes: :local`, both `:same_node` and `:all_nodes` retry on the same
  local machine since there's only one node.

  Use `normalize_retry/1` to convert a raw config value to the standard tuple
  format. Zero, negative numbers, strings, and other formats are invalid.

  ## Security Considerations

  - MFA tuples are validated to ensure modules are loaded and functions exist
  - Node lists are validated to prevent routing to invalid destinations
  - Permission modes are checked against available request fields
  - Timeout values are bounded to prevent resource exhaustion
  """

  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Structs.Request

  require Logger

  @max_timeout 300_000
  @min_timeout 100

  @type t :: %__MODULE__{
          request_type: String.t(),
          service: atom() | String.t(),
          nodes: list(atom()) | {module(), function(), args :: list()} | :local,
          choose_node_mode: :random | :hash | {:hash, String.t()} | :round_robin,
          timeout: integer() | :infinity,
          mfa: {module(), function(), args :: list()},
          arg_types: map() | nil,
          arg_orders: list(String.t()) | :map,
          response_type: :sync | :async | :stream | :none,
          check_permission: false | :any_authenticated | {:arg, String.t()} | {:role, list()},
          request_info: boolean(),
          version: String.t(),
          disabled: boolean,
          retry: {:same_node, number()} | {:all_nodes, number()} | number() | nil,
          before_execute: {module(), atom()} | {module(), atom(), args :: list()} | nil,
          after_execute: {module(), atom()} | {module(), atom(), args :: list()} | nil
        }

  defstruct [
    :request_type,
    :service,
    :nodes,
    :choose_node_mode,
    :timeout,
    :mfa,
    :arg_types,
    :arg_orders,
    :response_type,
    request_info: false,
    check_permission: false,
    version: "0.0.0",
    disabled: false,
    retry: nil,
    before_execute: nil,
    after_execute: nil
  ]

  @doc """
  Returns the version of the function configuration.
  If the version is not set or missing (for backward compatibility with old configs), returns "0.0.0" as default.
  """
  @spec version(t()) :: String.t()
  def version(config = %__MODULE__{}) do
    case Map.get(config, :version) do
      version when is_binary(version) and byte_size(version) > 0 ->
        version

      _ ->
        "0.0.0"
    end
  end

  @doc """
  Selects a target node for the request based on the `choose_node_mode` strategy.
  """
  def get_node(config = %__MODULE__{}, request = %Request{}) do
    NodeSelector.get_node(config, request)
  end

  @doc """
  Checks if the service is configured to run locally.
  """
  def is_local_service?(config = %__MODULE__{}) do
    config.nodes == :local
  end

  @doc """
  Validates and converts the request arguments based on the `arg_types` and `arg_orders` configuration.
  """
  def convert_args!(config = %__MODULE__{}, request = %Request{}) do
    ArgumentHandler.convert_args!(config, request)
  end

  @doc """
  Checks if the request has the necessary permissions to be executed.
  """
  def check_permission!(request = %Request{}, config = %__MODULE__{}) do
    Permission.check_permission!(request, config)
  end

  @doc """
  Validates the function configuration.

  Returns `true` if all configuration fields are valid, `false` otherwise.
  Logs detailed error messages for each invalid field.

  ## Validation Checks

  - `request_type` must be a non-empty string
  - `service` must not be nil
  - `nodes` must be a valid list, MFA tuple, or `:local`
  - `choose_node_mode` must be a recognized strategy
  - `timeout` must be a positive integer or `:infinity`
  - `mfa` must be a valid `{module, function, args}` tuple
  - `arg_types` and `arg_orders` must be consistent
  - `response_type` must be one of `:sync`, `:async`, `:stream`, or `:none`
  - `check_permission` must be a valid permission mode
  - `request_info` must be a boolean
  """
  def valid?(config = %__MODULE__{}) do
    validation_results = [
      request_type: valid_request_type?(config.request_type),
      service: config.service != nil,
      nodes: valid_nodes?(config.nodes),
      choose_node_mode: valid_choose_node_mode?(config.choose_node_mode),
      timeout: valid_timeout?(config.timeout),
      mfa: valid_mfa?(config.mfa),
      args: valid_args?(config.arg_types, config.arg_orders),
      response_type: config.response_type in [:sync, :async, :stream, :none],
      check_permission: valid_check_permission?(config.check_permission, config.arg_types),
      request_info: is_boolean(config.request_info),
      version: valid_version?(config.version),
      disabled: is_boolean(config.disabled),
      retry: valid_retry?(config.retry),
      before_execute: valid_hook?(config.before_execute),
      after_execute: valid_after_hook?(config.after_execute)
    ]

    invalid_keys =
      validation_results
      |> Enum.filter(fn {_, valid} -> valid == false end)
      |> Enum.map(fn {key, _} -> key end)

    if Enum.empty?(invalid_keys) do
      true
    else
      Logger.error(
        "PhoenixGenApi.FunConfig, invalid configurations: #{inspect(invalid_keys)} for #{inspect(config)}"
      )

      false
    end
  end

  @doc """
  Validates the function configuration and returns detailed error information.

  Returns `{:ok, config}` if valid, or `{:error, [error_messages]}` if invalid.
  """
  def validate_with_details(config = %__MODULE__{}) do
    errors = []

    errors =
      unless valid_request_type?(config.request_type) do
        ["request_type must be a non-empty string" | errors]
      else
        errors
      end

    errors =
      unless config.service != nil do
        ["service must not be nil" | errors]
      else
        errors
      end

    errors =
      unless valid_nodes?(config.nodes) do
        ["nodes must be a valid list, MFA tuple, or :local" | errors]
      else
        errors
      end

    errors =
      unless valid_choose_node_mode?(config.choose_node_mode) do
        ["choose_node_mode must be :random, :hash, {:hash, key}, or :round_robin" | errors]
      else
        errors
      end

    errors =
      unless valid_timeout?(config.timeout) do
        [
          "timeout must be a positive integer between #{@min_timeout} and #{@max_timeout}, or :infinity"
          | errors
        ]
      else
        errors
      end

    errors =
      unless valid_mfa?(config.mfa) do
        ["mfa must be a valid {module, function, args} tuple" | errors]
      else
        errors
      end

    errors =
      case validate_args_details(config.arg_types, config.arg_orders) do
        :ok -> errors
        {:error, reason} -> [reason | errors]
      end

    errors =
      unless config.response_type in [:sync, :async, :stream, :none] do
        ["response_type must be :sync, :async, :stream, or :none" | errors]
      else
        errors
      end

    errors =
      unless valid_check_permission?(config.check_permission, config.arg_types) do
        [
          "check_permission must be false, :any_authenticated, {:arg, arg_name}, or {:role, roles}"
          | errors
        ]
      else
        errors
      end

    errors =
      unless is_boolean(config.request_info) do
        ["request_info must be a boolean" | errors]
      else
        errors
      end

    errors =
      unless valid_version?(config.version) do
        ["version must be a valid version string (e.g., '1.0.0')" | errors]
      else
        errors
      end

    errors =
      unless valid_retry?(config.retry) do
        [
          "retry must be nil, a positive number, {:same_node, number}, or {:all_nodes, number}"
          | errors
        ]
      else
        errors
      end

    errors =
      unless valid_hook?(config.before_execute) do
        [
          "before_execute must be nil, {module, function}, or {module, function, args}"
          | errors
        ]
      else
        errors
      end

    errors =
      unless valid_after_hook?(config.after_execute) do
        [
          "after_execute must be nil, {module, function}, or {module, function, args}"
          | errors
        ]
      else
        errors
      end

    if Enum.empty?(errors) do
      {:ok, config}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp valid_request_type?(request_type)
       when is_binary(request_type) and byte_size(request_type) > 0, do: true

  defp valid_request_type?(_), do: false

  defp valid_nodes?(:local), do: true

  defp valid_nodes?(nodes) when is_list(nodes) do
    nodes != [] and Enum.all?(nodes, &is_valid_node?/1)
  end

  defp valid_nodes?({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: true

  defp valid_nodes?(_), do: false

  defp is_valid_node?(node) when is_atom(node), do: true
  defp is_valid_node?(node) when is_binary(node), do: true
  defp is_valid_node?(_), do: false

  defp valid_choose_node_mode?(:random), do: true
  defp valid_choose_node_mode?(:hash), do: true
  defp valid_choose_node_mode?({:hash, _key}), do: true
  defp valid_choose_node_mode?(:round_robin), do: true
  defp valid_choose_node_mode?(_), do: false

  defp valid_timeout?(:infinity), do: true

  defp valid_timeout?(timeout)
       when is_integer(timeout) and timeout >= @min_timeout and timeout <= @max_timeout,
       do: true

  defp valid_timeout?(_), do: false

  defp valid_mfa?({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    # Note: We don't check Code.ensure_loaded? here because configs are pulled
    # from remote nodes where the module may not exist locally.
    true
  end

  defp valid_mfa?(_), do: false

  defp valid_check_permission?(false, _), do: true
  defp valid_check_permission?(:any_authenticated, _), do: true

  defp valid_check_permission?({:arg, arg}, args) when is_map(args) do
    Map.has_key?(args, arg)
  end

  defp valid_check_permission?({:role, roles}, _args) when is_list(roles) do
    roles != []
  end

  defp valid_check_permission?(_, _), do: false

  defp valid_args?(nil, nil), do: true
  defp valid_args?(nil, arg_orders) when arg_orders == [] or arg_orders == nil, do: true
  defp valid_args?(nil, _), do: false

  defp valid_args?(arg_types, arg_orders) when is_map(arg_types) and map_size(arg_types) == 0 do
    arg_orders == [] or arg_orders == nil
  end

  defp valid_args?(arg_types, :map) when is_map(arg_types) and map_size(arg_types) > 0, do: true

  defp valid_args?(arg_types, arg_orders) when is_map(arg_types) and map_size(arg_types) == 1 do
    arg_orders == [] or arg_orders == nil or
      MapSet.new(Map.keys(arg_types)) == MapSet.new(arg_orders)
  end

  defp valid_args?(_arg_types, nil), do: false

  defp valid_args?(arg_types, arg_orders)
       when is_map(arg_types) and is_list(arg_orders) and
              map_size(arg_types) != length(arg_orders),
       do: false

  defp valid_args?(arg_types, arg_orders) when is_map(arg_types) and is_list(arg_orders) do
    MapSet.new(Map.keys(arg_types)) == MapSet.new(arg_orders)
  end

  defp valid_args?(_, _), do: false

  defp valid_version?(version) when is_binary(version) and byte_size(version) > 0, do: true
  defp valid_version?(_), do: false

  defp valid_retry?(nil), do: true
  defp valid_retry?(n) when is_number(n) and n > 0, do: true
  defp valid_retry?({:same_node, n}) when is_number(n) and n > 0, do: true
  defp valid_retry?({:all_nodes, n}) when is_number(n) and n > 0, do: true
  defp valid_retry?(_), do: false

  defp valid_hook?(nil), do: true

  defp valid_hook?({mod, fun}) when is_atom(mod) and is_atom(fun) do
    function_exported?(mod, fun, 2)
  end

  defp valid_hook?({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    function_exported?(mod, fun, 2 + length(args))
  end

  defp valid_hook?(_), do: false

  # After hooks take 3 args: (request, fun_config, result) + optional extra args
  defp valid_after_hook?(nil), do: true

  defp valid_after_hook?({mod, fun}) when is_atom(mod) and is_atom(fun) do
    function_exported?(mod, fun, 3)
  end

  defp valid_after_hook?({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    function_exported?(mod, fun, 3 + length(args))
  end

  defp valid_after_hook?(_), do: false

  @doc """
  Normalizes the retry configuration into a standard tuple format.

  - `nil` remains `nil` (no retry)
  - A number `n` is converted to `{:all_nodes, n}`
  - `{:same_node, n}` and `{:all_nodes, n}` are returned as-is

  ## Examples

      iex> FunConfig.normalize_retry(nil)
      nil

      iex> FunConfig.normalize_retry(3)
      {:all_nodes, 3}

      iex> FunConfig.normalize_retry({:same_node, 2})
      {:same_node, 2}

      iex> FunConfig.normalize_retry({:all_nodes, 5})
      {:all_nodes, 5}
  """
  @spec normalize_retry(nil | number() | {:same_node, number()} | {:all_nodes, number()}) ::
          nil | {:same_node, pos_integer()} | {:all_nodes, pos_integer()}
  def normalize_retry(nil), do: nil
  def normalize_retry(n) when is_number(n), do: {:all_nodes, trunc(n)}
  def normalize_retry({:same_node, n}) when is_number(n), do: {:same_node, trunc(n)}
  def normalize_retry({:all_nodes, n}) when is_number(n), do: {:all_nodes, trunc(n)}

  defp validate_args_details(nil, nil), do: :ok
  defp validate_args_details(nil, arg_orders) when arg_orders == [] or arg_orders == nil, do: :ok
  defp validate_args_details(nil, _), do: {:error, "arg_types is nil but arg_orders is not empty"}

  defp validate_args_details(arg_types, arg_orders)
       when is_map(arg_types) and map_size(arg_types) == 0 do
    if arg_orders == [] or arg_orders == nil do
      :ok
    else
      {:error, "arg_types is empty but arg_orders is not"}
    end
  end

  defp validate_args_details(arg_types, arg_orders)
       when is_map(arg_types) and is_list(arg_orders) do
    if map_size(arg_types) != length(arg_orders) do
      {:error,
       "arg_types count (#{map_size(arg_types)}) does not match arg_orders count (#{length(arg_orders)})"}
    else
      args_set = MapSet.new(Map.keys(arg_types))
      orders_set = MapSet.new(arg_orders)

      if MapSet.equal?(args_set, orders_set) do
        :ok
      else
        missing = MapSet.difference(args_set, orders_set) |> MapSet.to_list()
        extra = MapSet.difference(orders_set, args_set) |> MapSet.to_list()
        {:error, "arg mismatch, missing: #{inspect(missing)}, extra: #{inspect(extra)}"}
      end
    end
  end

  defp validate_args_details(arg_types, :map) when is_map(arg_types) and map_size(arg_types) > 0,
    do: :ok

  defp validate_args_details(_, _), do: {:error, "invalid arg_types or arg_orders format"}
end
