defmodule PhoenixGenApi.Helpers.Shared do
  @moduledoc """
  Shared utility functions used across PhoenixGenApi modules.

  This module centralizes common logic that was previously duplicated
  across ConfigPuller, ConfigReceiver, PushConfig, FunConfig, and NodeSelector.
  """

  alias PhoenixGenApi.Structs.FunConfig

  require Logger

  @doc """
  Compares two service names for equality, handling atom↔string comparisons.

  Service names can be atoms or strings throughout the system. This function
  normalizes the comparison so that `:my_service` and `"my_service"` are
  considered the same service.

  ## Examples

      iex> same_service?(:my_service, "my_service")
      true

      iex> same_service?("my_service", :my_service)
      true

      iex> same_service?(:my_service, :other_service)
      false
  """
  @spec same_service?(atom() | String.t(), atom() | String.t()) :: boolean()
  def same_service?(fun_service, push_service)
      when is_atom(fun_service) and is_atom(push_service) do
    fun_service == push_service
  end

  def same_service?(fun_service, push_service)
      when is_binary(fun_service) and is_binary(push_service) do
    fun_service == push_service
  end

  def same_service?(fun_service, push_service)
      when is_atom(fun_service) and is_binary(push_service) do
    Atom.to_string(fun_service) == push_service
  end

  def same_service?(fun_service, push_service)
      when is_binary(fun_service) and is_atom(push_service) do
    fun_service == Atom.to_string(push_service)
  end

  def same_service?(_, _), do: false

  @doc """
  Enforces that a FunConfig's service name matches the expected service.

  If the service names don't match, logs a warning and overwrites the
  FunConfig's service with the expected service name.

  ## Parameters

    - `config` - A `%FunConfig{}` struct
    - `service_name` - The expected service name (atom or string)

  ## Returns

  The FunConfig with the correct service name.
  """
  @spec enforce_service_name(FunConfig.t(), atom() | String.t()) :: FunConfig.t()
  def enforce_service_name(config = %FunConfig{}, service_name) do
    if same_service?(config.service, service_name) do
      config
    else
      Logger.warning(
        "[Shared] service_name mismatch in FunConfig, request_type: #{inspect(config.request_type)}, expected: #{inspect(service_name)}, got: #{inspect(config.service)}, overwriting"
      )

      %FunConfig{config | service: service_name}
    end
  end

  @doc """
  Ensures a FunConfig has a version string, defaulting to "0.0.0".

  If the FunConfig's version is nil or empty, sets it to "0.0.0".

  ## Parameters

    - `config` - A `%FunConfig{}` struct

  ## Returns

  The FunConfig with a guaranteed version string.
  """
  @spec ensure_version(FunConfig.t()) :: FunConfig.t()
  def ensure_version(config = %FunConfig{}) do
    if Map.has_key?(config, :version) and is_binary(config.version) and
         byte_size(config.version) > 0 do
      config
    else
      Logger.debug(
        "[Shared] adding default version \"0.0.0\" to config, request_type: #{inspect(config.request_type)}"
      )

      %FunConfig{config | version: "0.0.0"}
    end
  end

  @doc """
  Validates that a value is a valid node identifier.

  A valid node is either an atom (e.g., `:node1@host`) or a binary string
  (e.g., `"node1@host"`).

  ## Examples

      iex> valid_node?(:node1@host)
      true

      iex> valid_node?("node1@host")
      true

      iex> valid_node?(123)
      false
  """
  @spec valid_node?(any()) :: boolean()
  def valid_node?(node) when is_atom(node), do: true
  def valid_node?(node) when is_binary(node), do: true
  def valid_node?(_), do: false

  @doc """
  Validates a list of nodes, filtering out invalid entries.

  ## Parameters

    - `nodes` - A list of potential node identifiers

  ## Returns

  A list containing only valid node identifiers.
  """
  @spec validate_nodes(list()) :: list()
  def validate_nodes(nodes) when is_list(nodes) do
    Enum.filter(nodes, &valid_node?/1)
  end

  def validate_nodes(_), do: []
end
