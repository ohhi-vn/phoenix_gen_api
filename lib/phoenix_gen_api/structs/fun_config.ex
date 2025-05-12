defmodule PhoenixGenApi.Structs.FunConfig do
  @moduledoc """
  For declare a general config for a function.

  ## Summary

  Based on function config, the request will be forwarded to the target service.
  Params will be validated & converted to the correct types before forwarding.
  The response will be handled based on the response type.

  For basic check permission, it will check if the user_id of the request is the same as the user_id in the argument (indicated by `check_permission`, ex: check_permission: {:arg, arg_name}).

  For advanced permission check, please pass the request_info to the target function for checking.

  ## Example

  Below is an example of a function config:

  ```Elixir
  %FunConfig{
    request_type: "get_user",
    service: :user,
    nodes: ["user1", "user2"],
    choose_node_mode: :random,
    timeout: 1000,
    mfa: {User, :get_user, []},
    arg_types: %{
      "user_id" => :string,
      "device_id" => :string,
    },
    arg_orders: ["user_id", "device_id"],
    response_type: :async,
    check_permission: false,
    request_info: true,
  }
  ```

  Explain:

  - `request_type`: the unique identifier for the type of request & response.
    This is unqiue name in system for cliet can call right function.

  - `service`: the service that will handle the request.

  - `nodes`: the nodes that will handle the request. You can choose local node by set to `:local`.
    Currently, all nodes must have the same config.

  - `choose_node_mode`: the way to chose node, support: `:random`, `:hash`, `:round_robin`.

  - `timeout`: the timeout for the request.

  - `mfa`: the module, function, and arguments that will be called to handle the request.

  - `arg_types`: the types of the arguments that will be passed to the function. For validation & converting.

  - `arg_orders`: the order of the arguments that will be passed to the function.

  - `response_type`: indicates if the request has a response. Type of response: `:sync`, `:async`, `:stream`, `:none`.

  - `check_permission`: check permission, false or `{:arg, arg_name}`.

  - `request_info`: indicates if need request info, info will be added to the request in the last argument.
    `%{request_id: request_id, user_id: user_id, device_id: device_id}`.
    `user_id` is the user_id of the user who made the request.
  """

  @type t :: %__MODULE__{
    request_type: String.t(),
    service: atom() | String.t(),
    nodes: list(String.t()) | {module(), function(), args :: list()},
    choose_node_mode: atom(),
    timeout: integer() | :infinity,
    mfa: {module(), function(), args :: list()},
    arg_types: map() | nil,
    arg_orders: list(String.t()),
    response_type: :sync | :async | :stream | :none,
    check_permission: false | {:arg, String.t()},
    request_info: boolean()
  }

  alias __MODULE__

  alias PhoenixGenApi.Structs.Request

  # default max string length for data from client.
  @default_string_max_length 1000
  @default_list_max_items 1000
  @default_map_max_items 1000

  require Logger

  defstruct [
    # string, an unique identifier for the type of request & response.
    :request_type,
    # service.
    :service,
    # list, nodes that will handle the request.
    # for local service run same node set to :local
    :nodes,
    # way to chose node, support: :random, :hash, :round_robin,
    :choose_node_mode,
    # the timeout for the request.
    :timeout,
    # the module, function, and arguments that will be called to handle the request.
    :mfa,
    # map, field -> type, the types of the arguments that will be passed to the function. For validation & converting.
    # if nil or empty map, function has no arguments.
    # Support follow types:
    # :string - String type.
    # :boolean - boolean type.
    # :num - number type (integer or float).
    # :list_string - list of string.
    # :list_num - list of number.
    # :list - mix list, ex: [1, "a", true].
    # :map - map type. Not support nested map yet.
    :arg_types,
    # list, the order of the arguments that will be passed to the function.
    :arg_orders,
    # indicates if the request has a response. Type of response: :sync, :async, :none.
    # :sync -> the response will call directly & send back to the client.
    # :async -> Add to queue for other process to handle and send back to the client.
    # :stream -> stream the response to the client.
    # :none -> no response needed, using for updating or sending notification.
    :response_type,
    # boolean, indicates if need request info, info will be added to the request in the last argument.
    # %{request_id: request_id, user_id: user_id, device_id: device_id}
    # user_id is the user_id of the user who made the request.
    request_info: false,
    # check permission, false or {:arg, arg_name}
    # false, ignore basic check permission.
    # {:arg, arg_name}, verify if request from user has same user_id in argument.
    # arg type need to be :string.
    # basic check permission run in gen api service before forward to target service.
    # if user_id in request_info not match with user_id in argument, return error.
    # other case, please pass request_info to target function for checking.
    check_permission: false, # TO-DO: Support more complex permission check.
  ]

  @doc """
  Select target based on config.
  """
  def get_node(config = %FunConfig{nodes: {m, f, a}}, request = %Request{}) do
    case apply(m, f, a) do
      nodes when is_list(nodes) ->
        config = %FunConfig{config | nodes: nodes}
        get_node(config, request)
      other ->
        Logger.error("gen_api, get_node, invalid nodes #{inspect other}")
        raise "invalid nodes #{inspect other}"
    end

  end
  def get_node(config = %FunConfig{}, request = %Request{}) do
     # TO-DO: Implement sticky node selection.
    case config.choose_node_mode do
      :random -> Enum.random(config.nodes)
      :hash -> hash_node(request, config)
      :round_robin -> round_robin_node(request, config)
    end
  end

  @doc """
  Check if the service is local (run on the same node).
  """
  def is_local_service?(config = %FunConfig{}) do
    config.nodes == :local
  end

  @doc """
  Validate & Convert request arguments to the correct types.
  """
  def convert_args!(config = %FunConfig{}, request = %Request{}) do
    validate_args!(config, request)

    args = request.args
    arg_types = config.arg_types

    converted_args = Enum.reduce(args, %{}, fn {name, value}, acc ->
      type = arg_types[name]
      Map.put(acc, name, convert_arg!(value, type))
    end)

    cond do
      # function has no arguments.
      arg_types == nil or map_size(arg_types) == 0 ->
        []

      # function has only one argument.
      map_size(arg_types) == 1 ->
        Map.values(converted_args)

      # function has multiple arguments.
      true ->
        result = Enum.reduce(config.arg_orders, [], fn name, acc ->
          case Map.get(converted_args, name) do
            nil ->
              Logger.error("gen_api, request, missing argument #{inspect name} in #{inspect request.request_type}")
              raise "missing argument #{inspect name} in #{inspect request.request_type}"
            arg ->
              acc ++ [arg]
          end
        end)
        Logger.debug("gen_api, request, converted args: #{inspect result}")
        result
    end
  end

  @doc """
  Validate request arguments.
  """
  def validate_args!(%FunConfig{arg_types: nil},  %Request{}) do
    :ok
  end

  def validate_args!(%FunConfig{arg_types: %{}}, %Request{}) do
    :ok
  end

  def validate_args!(config = %FunConfig{}, request = %Request{}) do
    args = request.args
    arg_types = config.arg_types

    if map_size(args) != map_size(arg_types) do
      Logger.error("gen_api, request, invalid number of arguments for #{inspect request.request_type}, request_id: #{inspect request.request_id}")
      raise "invalid number of arguments for #{inspect request.request_type}"
    end

    config_args = MapSet.new(Map.keys(arg_types))
    request_args = MapSet.new(Map.keys(args))

    if !MapSet.equal?(config_args, request_args) do
      Logger.error("gen_api, request, invalid arguments for #{inspect request.request_type}, request_id: #{inspect request.request_id}")
      raise "invalid arguments for #{inspect request.request_type}"
    end

    # Verify argument types & values.
    Enum.each(args, fn {name, value} ->
     case arg_types[name] do
       :list ->
          if length(value) > @default_list_max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect name} in #{inspect request.request_type}, request_id: #{inspect request.request_id}")
            raise "invalid argument size for #{inspect name} in #{inspect request.request_type}"
          end
          arg_list_validation!(value)
        {:list, max_items} ->
          if length(value) > max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect name} in #{inspect request.request_type}, request_id: #{inspect request.request_id}")
            raise "invalid argument size for #{inspect name} in #{inspect request.request_type}"
          end
          arg_list_validation!(value)

        :map ->  # TO-DO: Implement more for map type validation.
          if map_size(value) > @default_map_max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect name} in #{inspect request.request_type}, request_id: #{inspect request.request_id}")
            raise "invalid argument size for #{inspect name} in #{inspect request.request_type}"
          end

          arg_map_validation!(value)


        {:map, max_items} ->  # TO-DO: Implement more for map type validation.
          if map_size(value) > max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect name} in #{inspect request.request_type}, request_id: #{inspect request.request_id}")
            raise "invalid argument size for #{inspect name} in #{inspect request.request_type}"
          end
          arg_map_validation!(value)
        other ->
          arg_validation!(other, value)
     end
    end)
  end

  defp arg_map_validation!(value) when is_map(value) do
    Enum.each( value, fn {_key, val} ->
      cond do
        is_boolean(val) ->
          :ok
        is_float(val) or is_integer(val) ->
          :ok
        is_binary(val) ->
          arg_validation!(:string, val)
        is_list(val) ->
          arg_validation!(:list, val)
        is_map(val) ->
          Logger.error("gen_api, request, nested map is not supported yet")
          raise "nested map is not supported yet"
      end
    end)
  end

  defp arg_list_validation!(value) when is_list(value) do
    Enum.each( value, fn item->
      cond do
        is_boolean(item) ->
          :ok
        is_float(item) or is_integer(item) ->
          :ok
        is_binary(item) ->
          arg_validation!(:string, item)
        is_map(item) ->
          Logger.error("gen_api, request, nested map is not supported yet")
          raise "nested map is not supported yet"
        is_list(item) ->
          Logger.error("gen_api, request, nested list is not supported yet")
          raise "nested list is not supported yet"
        true ->
          Logger.error("gen_api, request, unsupported type #{inspect item}")
          raise "unsupported type #{inspect item}"
      end
    end)
  end

  defp arg_list_validation!(value, fn_valid?) when is_list(value) do
    Enum.each( value, fn item->
      if fn_valid?.(item) do
        :ok
      else
        Logger.error("gen_api, request, unsupported type #{inspect item} in list")
        raise "unsupported type of #{inspect item} in list"
      end
    end)
  end

  defp arg_validation!(_type, nil) do
    Logger.error("gen_api, request, invalid argument type for nil")
    raise "invalid argument, not accept nil"
  end

  defp arg_validation!(type, value) do
    case type do
      nil ->
         Logger.error("gen_api, request, invalid argument type for #{inspect value}")
         raise "invalid argument type for #{inspect value}"

      :boolean ->
         if value in [true, false] do
           :ok
         else
           Logger.error("gen_api, request, invalid argument type for #{inspect value}")
           raise "invalid argument type for #{inspect value}"
         end
      :num ->
         if is_float(value) or is_integer(value) do
           :ok
         else
           Logger.error("gen_api, request, invalid argument type for #{inspect value}")
           raise "invalid argument type for #{inspect value}"
         end

      :string ->
         if String.length(value) > @default_string_max_length do
           Logger.error("gen_api, request, invalid argument size for #{inspect value}")
           raise "invalid argument size for #{inspect value}"
         end

      {:string, max_length} ->
        if String.length(value) > max_length do
          Logger.error("gen_api, request, invalid argument size for #{inspect value}")
          raise "invalid argument size for #{inspect value}"
        end

      :list ->
          if length(value) > @default_list_max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect value}")
            raise "invalid argument size for #{inspect value}"
          end
          arg_list_validation!(value)

      :list_string ->
          if length(value) > @default_list_max_items do
           Logger.error("gen_api, request, invalid argument size for #{inspect value}")
           raise "invalid argument size for #{inspect value}"
         end
         arg_list_validation!(value, fn item -> is_binary(item) and String.length(item) < @default_string_max_length end)

       {:list_string, max_items, max_item_length} ->
          if length(value) > max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect value}")
            raise "invalid argument size for #{inspect value}"
          end
          arg_list_validation!(value, fn item -> is_binary(item) and String.length(item) < max_item_length end)

       :list_num ->
          if length(value) > @default_list_max_items do
            Logger.error("gen_api, request, invalid argument size for #{inspect value}")
            raise "invalid argument size for #{inspect value}"
          end
          arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)

       {:list_num, max_items} ->
         if length(value) > max_items do
           Logger.error("gen_api, request, invalid argument size for #{inspect value}")
           raise "invalid argument size for #{inspect value}"
         end
          arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)

       _ ->
          Logger.error("gen_api, request, unsupported type #{inspect type} for #{inspect value}")
          raise "unsupported type #{inspect type} for #{inspect value}"
    end
  end

  ## private functions ##

  defp hash_node(request, config) do
    hash_order = :erlang.phash2(request.request_id, length(config.nodes))
    Enum.at(config.nodes, hash_order)
  end

  defp round_robin_node(_request, config) do
    node_num = config.nodes |> length() |> next_round_robin_node_num()
    Enum.at(config.nodes, node_num)
  end

  # Get next node number for round robin mode
  defp next_round_robin_node_num(1) do
    0
  end
  defp next_round_robin_node_num(nodes_length) do
    case Process.get(:round_robin_num, nil) do
      nil ->
        Process.put(:round_robin_num, 0)
        0
      curr_num ->
        next_num = curr_num + 1
        if next_num < nodes_length do
          Process.put(:round_robin_num, next_num)
          next_num
        else
          Process.put(:round_robin_num, 0)
          0
        end
    end
  end
  # defp next_round_robin_node_num(nodes_length) do
  #   next_num = Process.get(:round_robin_num, 0) + 1
  #   if next_num < nodes_length do
  #     Process.put(:round_robin_num, next_num)
  #     next_num
  #   else
  #     Process.put(:round_robin_num, 0)
  #     0
  #   end
  # end

  defp convert_arg!(arg, :string) when is_binary(arg) do
    arg
  end
  defp convert_arg!(arg, :boolean) when arg in [true, false] do
    arg
  end
  defp convert_arg!(arg, :num) when is_float(arg) or is_integer(arg) do
    arg
  end
  defp convert_arg!(arg, :list_string) when is_list(arg) do
    Enum.each(arg, fn
      x when is_binary(x) -> x
      x -> raise "invalid type #{inspect x} for list_string"
    end)

    arg
  end
  defp convert_arg!(arg, :list_num) when is_list(arg) do
    Enum.each(arg, fn
      x when is_float(x) or is_integer(x) -> x
      x -> raise "invalid type #{inspect x} for list_num"
    end)

    arg
  end

  defp convert_arg!(arg, :list) when is_list(arg) do
    arg
  end

  defp convert_arg!(arg, :map) when is_map(arg) do
    arg
  end

  defp convert_arg!(arg, type) do
    Logger.error("gen_api, request, unsupported type #{inspect type} for #{inspect arg}")
    raise "unsupported type #{inspect type} for #{inspect arg}"
  end

  @doc """
  Check permission for request from client.
  """
  def check_permission(%Request{}, %FunConfig{check_permission: false}) do
    true
  end

  def check_permission(request = %Request{},  %FunConfig{check_permission: {:arg, arg_name}}) do
    case Map.get(request.args, arg_name) do
      nil ->
        Logger.warning("gen_api, check permission, missing argument #{inspect arg_name} in request: #{inspect request}")
        false
      user_id ->
        user_id == request.user_id
    end
  end

  def check_permission!(request = %Request{}, fun_config = %FunConfig{}) do
    if not check_permission(request, fun_config) do
      Logger.warning(" gen_api, check permission, failed, request: #{inspect request}, fun config: #{inspect fun_config}")
      raise "Permission denied for request from user: #{inspect request.user_id}, request: #{inspect request.request_id}"
    end
  end

end
