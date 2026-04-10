defmodule PhoenixGenApi.Structs.ServiceConfig do
  @moduledoc """
  Service configuration struct that defines how to connect to a remote service
  and pull its function configurations.

  ## Version Checking

  When `version_module` and `version_function` are configured, the `ConfigPuller`
  will first call the lightweight version check RPC before performing a full
  config pull. If the returned version matches the locally stored version for
  that service, the full pull is skipped — saving network bandwidth and
  reducing load on remote nodes.

  The remote service should implement a version function that returns a value
  that changes whenever the function configurations change. Good candidates
  include:

    - A monotonically increasing integer (e.g., `1`, `2`, `3`)
    - A semantic version string (e.g., `"1.2.3"`)
    - A content hash of the config data (e.g., `"a1b2c3d4"`)
    - A timestamp of the last config change (e.g., `"2024-01-15T10:30:00Z"`)

  The version value is compared using strict equality (`==`), so any format
  that can be compared this way will work.

  ## Example Configuration

      %ServiceConfig{
        service: "user_service",
        nodes: ["node1@host", "node2@host"],
        module: UserService.Api,
        function: :get_config,
        args: [],
        version_module: UserService.Api,
        version_function: :get_config_version,
        version_args: []
      }

  If `version_module` or `version_function` is `nil`, version checking is
  disabled and the full config pull will always be performed (backward
  compatible behavior).
  """

  alias __MODULE__

  @typedoc "Service configuration struct."

  @type t :: %__MODULE__{
          service: String.t(),
          nodes: list(String.t()) | {module(), atom(), list()},
          module: module(),
          function: atom(),
          args: list(),
          version_module: module() | nil,
          version_function: atom() | nil,
          version_args: list()
        }

  @derive Nestru.Decoder
  defstruct [
    # Service name — used as a key to group function configurations.
    :service,
    # List of node names (atoms) or an MFA tuple that resolves to a list of nodes.
    :nodes,
    # Module on the remote node that implements the config function.
    :module,
    # Function on the remote module that returns the list of `%FunConfig{}`.
    :function,
    # Arguments passed to the config function.
    :args,
    # Module on the remote node that implements the version check function.
    # When set (along with `version_function`), the puller will call this
    # before doing a full config pull. If the version matches the stored
    # version, the full pull is skipped.
    :version_module,
    # Function on `version_module` that returns the current config version.
    # Should return a value that changes whenever configs change.
    :version_function,
    # Arguments passed to the version check function.
    :version_args
  ]

  @doc """
  Creates a `ServiceConfig` struct from a map (typically from application config).

  Handles both atom and string keys, and converts string module/function names
  to atoms when necessary.
  """
  def from_map(config = %{}) do
    Nestru.decode!(config, ServiceConfig)
  end

  @doc """
  Returns `true` if version checking is configured for this service.

  A service is considered to have version checking enabled when both
  `version_module` and `version_function` are non-nil.
  """
  @spec version_check_enabled?(t()) :: boolean()
  def version_check_enabled?(%__MODULE__{
        version_module: mod,
        version_function: fun
      })
      when is_atom(mod) and not is_nil(mod) and is_atom(fun) and not is_nil(fun) do
    true
  end

  def version_check_enabled?(_), do: false
end
