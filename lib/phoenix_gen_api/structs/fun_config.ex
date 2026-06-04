defmodule PhoenixGenApi.Structs.FunConfig do
  @moduledoc """
  Defines the configuration for a function that can be called through the API.

  This struct holds all the necessary information to route, validate, and execute
  a function call based on an incoming request.

  ## Version

  The `version` field is a string (e.g., "1.0.0"). The value `"0.0.0"` is reserved
  as a sentinel and cannot be explicitly registered — it is used internally to
  mean "no version specified". If a config has no version set, `version/1` returns
  `nil` and the config is stored with a `nil` version key in the cache.

  ## Argument Types (arg_types)

  The `arg_types` field supports two formats:

  ### Simple Format (Backward Compatible)

  Uses just the type atom:

      arg_types: %{"user_id" => :string, "age" => :num}

  ### Extended Format (New)

  Uses a keyword list with `:type` and optional parameters:

      arg_types: %{
        "user_id" => [type: :string, max_bytes: 255, allow_nil?: true],
        "age" => [type: :num, default_value: 18],
        "tags" => [type: :list_string, max_items: 10, max_item_bytes: 100],
        "gps_list" => [type: :list_map, max_items: 100],
        "metadata" => [type: :map, max_items: 200, required: ["name"], accept: ["name", "email", "age"]]
      }

  #### Extended Format Options

  - `type:` - Required. The argument type (`:string`, `:num`, `:boolean`, etc.)
  - `allow_nil?:` - Optional. When `true`, allows nil values (default: `false`)
  - `default_value:` - Optional. Default value if argument is missing from request
  - `max_bytes:` - For `:string` type, max byte size
  - `max_items:` - For list/map types, max number of items
  - `max_item_bytes:` - For `:list_string`, max bytes per item
  - `required:` - For `:map` type only, list of required key names (e.g., `["name", "email"]`)
  - `accept:` - For `:map` type only, list of accepted key names — any key not in this list causes an error

  #### Validation

  - Default values are validated to match their declared type during config validation
  - Invalid default values will cause `FunConfig.validate_with_details/1` to return an error

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

  ## Hooks

  The `before_execute` and `after_execute` fields allow you to run custom code
  before and/or after a function is executed through the API. Hooks are specified
  as MFA tuples:

    - `{module, function}` — Called as `module.function(request, fun_config)` (before)
      or `module.function(request, fun_config, result)` (after).
    - `{module, function, extra_args}` — Extra arguments are appended.

  ### Before execute

  Must return one of:

    - `{:ok, request, fun_config}` — Proceed with (possibly modified) request/config.
    - `{:error, reason}` — Abort execution and return an error response.

  ### After execute

  Must return the (possibly modified) result. Any other return value is ignored and
  the original result is preserved.

  Hooks emit telemetry events at `[:phoenix_gen_api, :hook, :before|:after, :start|:stop|:exception]`.

  ## Permission Callback

  The `permission_callback` field allows a custom MFA to override the built-in
  `check_permission` modes. When set to `{module, function, args}` (or
  `{module, function}`), it is called as `apply(module, function, [request | args])`
  and must return `true` or `false`. Any other return, exception, or catch is
  treated as `false` (denied). When `permission_callback` is set, `check_permission`
  is ignored.

  ## Security Considerations

  - MFA tuples are validated to ensure modules are loaded and functions exist
  - Node lists are validated to prevent routing to invalid destinations
  - Permission modes are checked against available request fields
  - Timeout values are bounded to prevent resource exhaustion
  - Hook failures in `before_execute` abort the request; hook failures in `after_execute`
    are silently ignored (the original result is preserved)
  - Permission callbacks that raise exceptions are treated as denied (fail-closed)
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
          choose_node_mode:
            :random | :hash | {:hash, String.t()} | :round_robin | {:sticky, String.t()},
          timeout: integer() | :infinity,
          mfa: {module(), function(), args :: list()},
          arg_types: map() | nil,
          arg_orders: list(String.t()) | :map,
          response_type: :sync | :async | :stream | :none,
          check_permission: false | :any_authenticated | {:arg, String.t()} | {:role, list()},
          permission_callback: {module(), atom(), args :: list()} | nil,
          request_info: boolean(),
          version: String.t(),
          disabled: boolean,
          retry: {:same_node, number()} | {:all_nodes, number()} | number() | nil,
          before_execute: {module(), atom()} | {module(), atom(), args :: list()} | nil,
          after_execute: {module(), atom()} | {module(), atom(), args :: list()} | nil,
          hook_timeout: pos_integer()
        }

  @no_version_sentinel "0.0.0"

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
    permission_callback: nil,
    version: nil,
    disabled: false,
    retry: nil,
    before_execute: nil,
    after_execute: nil,
    hook_timeout: 5000
  ]

  @doc """
  Returns the version of the function configuration.
  If the version is not set, is `"0.0.0"` (reserved sentinel), or is empty,
  returns `nil` to indicate no version was specified.
  """
  @spec version(t()) :: String.t() | nil
  def version(config = %__MODULE__{}) do
    case Map.get(config, :version) do
      version when is_binary(version) and byte_size(version) > 0 and version != "0.0.0" ->
        version

      _ ->
        nil
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
  def local_service?(config = %__MODULE__{}) do
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
    case validate_with_details(config) do
      {:ok, _} ->
        true

      {:error, errors} ->
        Logger.error(
          "[FunConfig] validation failed, errors: #{inspect(errors)}, request_type: #{inspect(config.request_type)}, service: #{inspect(config.service)}, nodes: #{inspect(config.nodes)}, mfa: #{inspect(config.mfa)}, response_type: #{inspect(config.response_type)}, check_permission: #{inspect(config.check_permission)}, retry: #{inspect(config.retry)}, version: #{inspect(config.version)}"
        )

        false
    end
  end

  @doc """
  Validates the function configuration and returns detailed error information.

  Returns `{:ok, config}` if valid, or `{:error, [error_messages]}` if invalid.
  """
  def validate_with_details(config = %__MODULE__{}) do
    validations = [
      {valid_request_type?(config.request_type), "request_type must be a non-empty string"},
      {config.service != nil, "service must not be nil"},
      {valid_nodes?(config.nodes), "nodes must be a valid list, MFA tuple, or :local"},
      {valid_choose_node_mode?(config.choose_node_mode),
       "choose_node_mode must be :random, :hash, {:hash, key}, :round_robin, or {:sticky, key}"},
      {valid_timeout?(config.timeout),
       "timeout must be a positive integer between #{@min_timeout} and #{@max_timeout}, or :infinity"},
      {valid_mfa?(config.mfa), "mfa must be a valid {module, function, args} tuple"},
      {validate_args_details(config.arg_types, config.arg_orders) == :ok,
       "argument validation failed"},
      {config.response_type in [:sync, :async, :stream, :none],
       "response_type must be :sync, :async, :stream, or :none"},
      {valid_check_permission?(config.check_permission, config.arg_types),
       "check_permission must be false, :any_authenticated, {:arg, arg_name}, or {:role, roles}"},
      {valid_permission_callback?(config.permission_callback),
       "permission_callback must be nil or a valid {module, function, args} tuple"},
      {is_boolean(config.request_info), "request_info must be a boolean"},
      {valid_version?(config.version), "version must be a valid version string (e.g., '1.0.0')"},
      {valid_retry?(config.retry),
       "retry must be nil, a positive number, {:same_node, number}, or {:all_nodes, number}"},
      {valid_hook?(config.before_execute),
       "before_execute must be nil or a valid {module, function} or {module, function, args} tuple"},
      {valid_hook?(config.after_execute),
       "after_execute must be nil or a valid {module, function} or {module, function, args} tuple"},
      {valid_hook_timeout?(config.hook_timeout), "hook_timeout must be a positive integer"}
    ]

    errors =
      Enum.reduce(validations, [], fn {valid?, error_msg}, acc ->
        if valid?, do: acc, else: [error_msg | acc]
      end)

    if Enum.empty?(errors) do
      {:ok, config}
    else
      {:error, Enum.reverse(errors)}
    end
  end

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

  defp validate_args_details(nil, arg_orders)
       when arg_orders == [] or arg_orders == nil,
       do: :ok

  defp validate_args_details(nil, _),
    do: {:error, "arg_types is nil but arg_orders is not empty"}

  defp validate_args_details(arg_types, arg_orders)
       when is_map(arg_types) and map_size(arg_types) == 0 do
    if arg_orders == [] or arg_orders == nil do
      :ok
    else
      {:error, "arg_types is empty but arg_orders is not"}
    end
  end

  defp validate_args_details(arg_types, []) when is_map(arg_types) and map_size(arg_types) > 0 do
    # Empty arg_orders with populated arg_types means arg order doesn't matter
    # Similar to :map mode - just validate each arg config
    invalid_args =
      Enum.filter(arg_types, fn {_name, arg_config} ->
        not valid_arg_config?(arg_config)
      end)

    if Enum.empty?(invalid_args) do
      :ok
    else
      {:error,
       "invalid arg_types configuration for: #{inspect(Enum.map(invalid_args, fn {name, _} -> name end))}"}
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
        # Validate each arg config
        invalid_args =
          Enum.filter(arg_types, fn {_name, arg_config} ->
            not valid_arg_config?(arg_config)
          end)

        if Enum.empty?(invalid_args) do
          :ok
        else
          {:error,
           "invalid arg_types configuration for: #{inspect(Enum.map(invalid_args, fn {name, _} -> name end))}"}
        end
      else
        missing = MapSet.difference(args_set, orders_set) |> MapSet.to_list()
        extra = MapSet.difference(orders_set, args_set) |> MapSet.to_list()
        {:error, "arg mismatch, missing: #{inspect(missing)}, extra: #{inspect(extra)}"}
      end
    end
  end

  defp validate_args_details(arg_types, :map)
       when is_map(arg_types) and map_size(arg_types) > 0 do
    # Validate each arg config
    invalid_args =
      Enum.filter(arg_types, fn {_name, arg_config} ->
        not valid_arg_config?(arg_config)
      end)

    if Enum.empty?(invalid_args) do
      :ok
    else
      {:error,
       "invalid arg_types configuration for: #{inspect(Enum.map(invalid_args, fn {name, _} -> name end))}"}
    end
  end

  defp validate_args_details(_, _), do: {:error, "invalid arg_types or arg_orders format"}

  # Private validation helpers

  @doc false
  defp valid_request_type?(request_type)
       when is_binary(request_type) and byte_size(request_type) > 0 do
    true
  end

  defp valid_request_type?(_), do: false

  @doc false
  defp valid_nodes?(nodes) when is_list(nodes) do
    nodes != [] and Enum.all?(nodes, &PhoenixGenApi.Helpers.Shared.valid_node?/1)
  end

  defp valid_nodes?(nodes) when is_tuple(nodes) do
    case nodes do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        true

      _ ->
        false
    end
  end

  defp valid_nodes?(:local), do: true
  defp valid_nodes?(_), do: false

  @doc false
  defp valid_choose_node_mode?(:random), do: true
  defp valid_choose_node_mode?(:hash), do: true
  defp valid_choose_node_mode?(:round_robin), do: true
  defp valid_choose_node_mode?({:hash, key}) when is_binary(key), do: true
  defp valid_choose_node_mode?({:sticky, key}) when is_binary(key), do: true
  defp valid_choose_node_mode?(_), do: false

  @doc false
  defp valid_timeout?(:infinity), do: true

  defp valid_timeout?(timeout)
       when is_integer(timeout) and timeout >= @min_timeout and timeout <= @max_timeout, do: true

  defp valid_timeout?(_), do: false

  @doc false
  defp valid_mfa?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    true
  end

  defp valid_mfa?(_), do: false

  @doc false
  defp valid_check_permission?(false, _arg_types), do: true
  defp valid_check_permission?(:any_authenticated, _arg_types), do: true
  defp valid_check_permission?({:arg, arg_name}, _arg_types) when is_binary(arg_name), do: true
  defp valid_check_permission?({:role, roles}, _arg_types) when is_list(roles), do: true
  defp valid_check_permission?(_, _), do: false

  @doc false
  defp valid_permission_callback?(nil), do: true

  defp valid_permission_callback?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args), do: true

  defp valid_permission_callback?({module, function}) when is_atom(module) and is_atom(function),
    do: true

  defp valid_permission_callback?(_), do: false

  @doc false
  defp valid_version?(nil), do: true
  defp valid_version?(@no_version_sentinel), do: false
  defp valid_version?(version) when is_binary(version) and byte_size(version) > 0, do: true
  defp valid_version?(_), do: false

  @doc false
  defp valid_retry?(nil), do: true
  defp valid_retry?(n) when is_number(n) and n > 0, do: true
  defp valid_retry?({:same_node, n}) when is_number(n) and n > 0, do: true
  defp valid_retry?({:all_nodes, n}) when is_number(n) and n > 0, do: true
  defp valid_retry?(_), do: false

  @doc false
  defp valid_arg_config?(arg_config) when is_atom(arg_config) do
    # Simple format - just a type atom
    arg_config in [
      :string,
      :num,
      :boolean,
      :list_string,
      :list_num,
      :list_uuid,
      :list_map,
      :map,
      :any,
      :uuid
    ]
  end

  defp valid_arg_config?(arg_config) when is_tuple(arg_config) do
    # Old tuple format: {:string, 255}, {:list, 10}, etc.
    case arg_config do
      {type, _value} when is_atom(type) ->
        type in [
          :string,
          :num,
          :boolean,
          :list_string,
          :list_num,
          :list_uuid,
          :list_map,
          :map,
          :any,
          :uuid
        ]

      _ ->
        false
    end
  end

  defp valid_arg_config?(arg_config) when is_list(arg_config) do
    # Extended format - keyword list with :type required
    case Keyword.get(arg_config, :type) do
      type
      when type in [
             :string,
             :num,
             :boolean,
             :list_string,
             :list_num,
             :list_uuid,
             :list_map,
             :map,
             :any,
             :uuid
           ] ->
        true

      _ ->
        false
    end
  end

  defp valid_arg_config?(_), do: false

  @doc false
  defp valid_hook?(nil), do: true
  defp valid_hook?({module, function}) when is_atom(module) and is_atom(function), do: true

  defp valid_hook?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args), do: true

  defp valid_hook?(_), do: false

  defp valid_hook_timeout?(timeout) when is_integer(timeout) and timeout > 0, do: true
  defp valid_hook_timeout?(_), do: false
end
