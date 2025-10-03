defmodule PhoenixGenApi.Structs.FunConfig do
  @moduledoc """
  Defines the configuration for a function that can be called through the API.

  This struct holds all the necessary information to route, validate, and execute
  a function call based on an incoming request.
  """

  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Structs.Request

  @type t :: %__MODULE__{
          request_type: String.t(),
          service: atom() | String.t(),
          nodes: list(String.t()) | {module(), function(), args :: list()},
          choose_node_mode: atom() | {atom(), atom()},
          timeout: integer() | :infinity,
          mfa: {module(), function(), args :: list()},
          arg_types: map() | nil,
          arg_orders: list(String.t()),
          response_type: :sync | :async | :stream | :none,
          check_permission: false | {:arg, String.t()},
          request_info: boolean()
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
    check_permission: false
  ]

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
end
