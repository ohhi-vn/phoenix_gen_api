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

  require Logger

  @type t :: %__MODULE__{
          request_type: String.t(),
          service: atom() | String.t(),
          nodes: list(atom()) | {module(), function(), args :: list()},
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

  @doc """
  Validates the function configuration.
  """
  # TO-DO: Add unittest for this function.
  def valid?(config = %__MODULE__{}) do
    incorrected_keys =
      [
        # choose_node_mode: NodeSelector.choose_node_valid?(config.choose_node_mode),
        response_type: config.response_type in [:sync, :async, :stream, :none],
        request_info: config.request_info in [true, false],
        service: config.service != nil,
        nodes: valid_nodes?(config.nodes),
        mfa: valid_mfa?(config.mfa),
        args: valid_args?(config.arg_types, config.arg_orders),
        check_permission: valid_check_permission?(config.check_permission, config.arg_types)
      ]
      |> Enum.filter(fn {_, valid} -> valid == false end)
      |> Enum.map(fn {key, _} -> key end)

    if Enum.empty?(incorrected_keys) do
      true
    else
      Logger.error("Invalid configurations: #{inspect(incorrected_keys)} for #{inspect(config)}")

      false
    end
  end

  defp valid_nodes?(nodes) do
    case nodes do
      [] -> false
      [_ | _] -> true
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      _ -> false
    end
  end

  defp valid_mfa?({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args), do: true
  defp valid_mfa?(_), do: false

  defp valid_check_permission?(false, _), do: true

  defp valid_check_permission?({:arg, arg}, args) do
    Map.has_key?(args, arg)
  end

  defp valid_args?(nil, nil), do: true
  defp valid_args?(nil, _arg_orders), do: false
  defp valid_args?(arg_types, _arg_orders) when map_size(arg_types) == 1, do: true
  defp valid_args?(_arg_types, nil), do: false

  defp valid_args?(arg_types, arg_orders) when map_size(arg_types) != length(arg_orders),
    do: false

  defp valid_args?(arg_types, arg_orders) do
    args = MapSet.new(Map.keys(arg_types))

    orders = MapSet.new(arg_orders)

    MapSet.equal?(args, orders)
  end
end
