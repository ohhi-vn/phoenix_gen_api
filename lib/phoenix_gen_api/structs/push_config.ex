defmodule PhoenixGenApi.Structs.PushConfig do
  @moduledoc """
  Represents the data a remote node pushes to the PhoenixGenApi server node.

  This struct is used when a remote node actively pushes its service configuration
  to the server, as opposed to the server pulling it. It contains all the
  necessary information to register the service, including function configurations
  and optional pull-based registration details.

  ## Version Checking

  The `config_version` field represents the version of the entire service
  configuration. When the server receives a push, it compares this version
  with the locally stored version. If they match, the push can be skipped
  since the server already has the current configuration.

  ## Auto-Pull Registration

  When `module` and `function` are provided, the `to_service_config/1` function
  can convert this `PushConfig` into a `ServiceConfig` for automatic pull-based
  registration. This allows the server to periodically refresh the configuration
  from the remote node after the initial push.

  ## Validation

  Use `valid?/1` for a quick boolean check or `validate_with_details/1` for
  detailed error messages when validation fails.

  ## Example

      %PushConfig{
        service: "user_service",
        nodes: [:"node1@host", :"node2@host"],
        config_version: "1.2.3",
        fun_configs: [%FunConfig{...}],
        module: UserService.Api,
        function: :get_config,
        args: [],
        version_module: UserService.Api,
        version_function: :get_config_version,
        version_args: []
      }
  """

  alias PhoenixGenApi.Structs.{FunConfig, ServiceConfig}

  require Logger

  @typedoc "Push configuration struct for remote node pushes."

  @type t :: %__MODULE__{
          service: atom() | String.t(),
          nodes: list(atom() | String.t()),
          config_version: String.t(),
          fun_configs: list(FunConfig.t()),
          module: module() | nil,
          function: atom() | nil,
          args: list(),
          version_module: module() | nil,
          version_function: atom() | nil,
          version_args: list(),
          push_token: String.t() | nil
        }

  @derive Nestru.Decoder
  defstruct [
    # Service name — used as a key to group function configurations.
    :service,
    # List of node names (atoms or strings) where this service runs.
    :nodes,
    # Version of the entire service config, used to detect if server
    # already has this version.
    :config_version,
    # List of `%FunConfig{}` structs defining the functions this service exposes.
    :fun_configs,
    # Module on the remote node for future pulls (optional).
    :module,
    # Function on the remote module for future pulls (optional).
    :function,
    # Module on the remote node for version checking (optional).
    :version_module,
    # Function on the remote module for version checking (optional).
    :version_function,
    # Arguments passed to the pull function.
    args: [],
    # Arguments passed to the version check function.
    version_args: [],
    # Push token for authenticating push requests to the gateway (optional).
    # When configured on the gateway via `:push_token`, push requests must
    # include a matching token.
    push_token: nil
  ]

  @doc """
  Creates a `PushConfig` struct from a map using Nestru for decoding.
  """
  def from_map(data = %{}) do
    Nestru.decode!(data, __MODULE__)
  end

  @doc """
  Validates the push configuration.

  Returns `true` if all configuration fields are valid, `false` otherwise.
  Logs detailed error messages for each invalid field.

  ## Validation Checks

  - `service` must not be nil
  - `nodes` must be a non-empty list of atoms or strings
  - `config_version` must be a non-empty string
  - `fun_configs` must be a non-empty list of `FunConfig` structs
  - All `fun_configs` must have the same service name as the push config
  - All `fun_configs` must have valid versions
  """
  @spec valid?(t()) :: boolean()
  def valid?(config = %__MODULE__{}) do
    case validate_with_details(config) do
      {:ok, _} ->
        true

      {:error, errors} ->
        Logger.error(
          "[PushConfig] validation failed, errors: #{inspect(errors)}, service: #{inspect(config.service)}, config_version: #{inspect(config.config_version)}"
        )

        false
    end
  end

  @doc """
  Validates the push configuration and returns detailed error information.

  Returns `{:ok, config}` if valid, or `{:error, [error_messages]}` if invalid.
  """
  @spec validate_with_details(t()) :: {:ok, t()} | {:error, [String.t()]}
  def validate_with_details(config = %__MODULE__{}) do
    validations = [
      {config.service != nil, "service must not be nil"},
      {valid_nodes?(config.nodes), "nodes must be a non-empty list of atoms or strings"},
      {valid_config_version?(config.config_version), "config_version must be a non-empty string"},
      {valid_fun_configs?(config.fun_configs),
       "fun_configs must be a non-empty list of FunConfig structs"},
      {fun_configs_match_service?(config.fun_configs, config.service),
       "all fun_configs must have the same service name as the push config"},
      {fun_configs_have_valid_versions?(config.fun_configs),
       "all fun_configs must have valid versions"}
    ]

    errors =
      validations
      |> Enum.filter(fn {valid?, _} -> not valid? end)
      |> Enum.map(fn {_, msg} -> msg end)

    if Enum.empty?(errors) do
      {:ok, config}
    else
      {:error, errors}
    end
  end

  @doc """
  Converts the `PushConfig` to a `ServiceConfig` for auto-pull registration.

  Only creates a `ServiceConfig` if both `module` and `function` are provided.
  Returns `nil` if either is missing.

  The resulting `ServiceConfig` can be used by the `ConfigPuller` to periodically
  refresh the configuration from the remote node.
  """
  @spec to_service_config(t()) :: ServiceConfig.t() | nil
  def to_service_config(%__MODULE__{
        service: service,
        nodes: nodes,
        module: mod,
        function: fun,
        args: args,
        version_module: version_module,
        version_function: version_function,
        version_args: version_args
      })
      when is_atom(mod) and not is_nil(mod) and is_atom(fun) and not is_nil(fun) do
    %ServiceConfig{
      service: service,
      nodes: nodes,
      module: mod,
      function: fun,
      args: args,
      version_module: version_module,
      version_function: version_function,
      version_args: version_args
    }
  end

  def to_service_config(_), do: nil

  # Private validation helpers

  defp valid_nodes?(nodes) when is_list(nodes) do
    nodes != [] and Enum.all?(nodes, &valid_node?/1)
  end

  defp valid_nodes?(_), do: false

  defp valid_node?(node), do: PhoenixGenApi.Helpers.Shared.valid_node?(node)

  defp valid_config_version?(version) when is_binary(version) and byte_size(version) > 0 do
    true
  end

  defp valid_config_version?(_), do: false

  defp valid_fun_configs?(fun_configs) when is_list(fun_configs) do
    fun_configs != [] and Enum.all?(fun_configs, &fun_config_struct?/1)
  end

  defp valid_fun_configs?(_), do: false

  defp fun_config_struct?(%FunConfig{}), do: true
  defp fun_config_struct?(_), do: false

  defp fun_configs_match_service?(fun_configs, service) when is_list(fun_configs) do
    Enum.all?(fun_configs, fn
      %FunConfig{service: fun_service} -> same_service?(fun_service, service)
      _ -> false
    end)
  end

  defp fun_configs_match_service?(_, _), do: false

  defp same_service?(fun_service, push_service),
    do: PhoenixGenApi.Helpers.Shared.same_service?(fun_service, push_service)

  defp fun_configs_have_valid_versions?(fun_configs) when is_list(fun_configs) do
    Enum.all?(fun_configs, fn
      %FunConfig{} = fun_config ->
        FunConfig.valid?(fun_config) or valid_version_string?(fun_config.version)

      _ ->
        false
    end)
  end

  defp fun_configs_have_valid_versions?(_), do: false

  defp valid_version_string?(version) when is_binary(version) and byte_size(version) > 0 do
    true
  end

  defp valid_version_string?(_), do: false
end
