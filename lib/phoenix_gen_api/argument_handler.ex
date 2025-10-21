defmodule PhoenixGenApi.ArgumentHandler do
  @moduledoc """
  Validates and converts request arguments according to configured type specifications.

  This module provides comprehensive argument validation and type conversion for API requests.
  It ensures that all request arguments match their expected types and sizes before function
  execution, preventing type errors and potential security issues.

  ## Supported Argument Types

  ### Basic Types
  - `:string` - String with max length of 3000 characters (default)
  - `{:string, max_length}` - String with custom max length
  - `:num` - Integer or float
  - `:boolean` - Boolean value (true/false)

  ### Collection Types
  - `:list` - Generic list with max 1000 items (default)
  - `{:list, max_items}` - List with custom max items
  - `:list_string` - List of strings, max 1000 items, each string max 3000 chars
  - `{:list_string, max_items, max_item_length}` - List of strings with custom limits
  - `:list_num` - List of numbers, max 1000 items
  - `{:list_num, max_items}` - List of numbers with custom max items
  - `:map` - Generic map with max 1000 items (default)
  - `{:map, max_items}` - Map with custom max items

  ## Size Limits (Defaults)

  - Strings: 3000 characters
  - Lists: 1000 items
  - Maps: 1000 entries

  These limits help prevent denial-of-service attacks through oversized payloads.

  ## Validation Rules

  1. **Type Matching**: Argument values must match their declared types
  2. **Size Limits**: Strings, lists, and maps must not exceed size limits
  3. **Required Arguments**: All declared arguments must be present
  4. **No Extra Arguments**: Requests cannot include undeclared arguments
  5. **No Nil Values**: Nil values are not accepted for any argument
  6. **No Nesting**: Nested lists and maps are not currently supported

  ## Examples

      # Configure argument types
      config = %FunConfig{
        arg_types: %{
          "username" => :string,
          "age" => :num,
          "email" => {:string, 255},
          "tags" => :list_string,
          "scores" => {:list_num, 100}
        },
        arg_orders: ["username", "age", "email", "tags", "scores"]
      }

      # Valid request
      request = %Request{
        args: %{
          "username" => "alice",
          "age" => 30,
          "email" => "alice@example.com",
          "tags" => ["elixir", "phoenix"],
          "scores" => [95, 87, 92]
        }
      }

      args = ArgumentHandler.convert_args!(config, request)
      # => ["alice", 30, "alice@example.com", ["elixir", "phoenix"], [95, 87, 92]]

      # Invalid request - wrong type
      request = %Request{
        args: %{
          "username" => "alice",
          "age" => "thirty",  # String instead of number
          "email" => "alice@example.com",
          "tags" => ["elixir"],
          "scores" => [95]
        }
      }

      ArgumentHandler.convert_args!(config, request)
      # ** (RuntimeError) invalid argument type for "thirty"

  ## Error Handling

  All validation functions raise `RuntimeError` on validation failures with descriptive
  messages. The `InvalidType` exception is raised for type conversion errors.

  ## Notes

  - Argument order is preserved based on `arg_orders` configuration
  - Functions with no arguments return an empty list
  - Single-argument functions return a list with one element
  - Validation happens before type conversion
  - Nested structures (maps in maps, lists in lists) are not supported
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.Errors.InvalidType

  require Logger

  @default_string_max_length 3000
  @default_list_max_items 1000
  @default_map_max_items 1000

  @doc """
  Validates and converts request arguments to the correct types and order.

  This function performs both validation and conversion in one step. It first validates
  that all required arguments are present with correct types and sizes, then converts
  them to the order specified in the configuration.

  ## Parameters

    - `config` - A `FunConfig` struct containing:
      - `arg_types` - Map of argument names to type specifications
      - `arg_orders` - List of argument names in the expected order

    - `request` - A `Request` struct containing the arguments to validate

  ## Returns

  A list of argument values in the order specified by `arg_orders`, or an empty list
  if the function has no arguments.

  ## Raises

    - `RuntimeError` - If validation fails (wrong type, size, missing args, etc.)
    - `InvalidType` - If type conversion fails

  ## Examples

      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{
        args: %{"name" => "Alice", "age" => 30}
      }

      ArgumentHandler.convert_args!(config, request)
      # => ["Alice", 30]
  """
  def convert_args!(config = %FunConfig{}, request = %Request{}) do
    validate_args!(config, request)

    args = request.args || %{}
    arg_types = config.arg_types || %{}

    converted_args =
      Enum.reduce(args, %{}, fn {name, value}, acc ->
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
        result =
          Enum.reduce(config.arg_orders, [], fn name, acc ->
            case Map.get(converted_args, name) do
              nil ->
                Logger.error(
                  "gen_api, request, missing argument #{inspect(name)} in #{inspect(request.request_type)}"
                )

                raise "missing argument #{inspect(name)} in #{inspect(request.request_type)}"

              arg ->
                acc ++ [arg]
            end
          end)

        Logger.debug("gen_api, request, converted args: #{inspect(result)}")
        result
    end
  end

  @doc """
  Validate request arguments.
  """
  def validate_args!(%FunConfig{arg_types: no_args}, %Request{})
      when no_args == nil or map_size(no_args) == 0 do
    :ok
  end

  def validate_args!(config = %FunConfig{}, request = %Request{}) do
    args = request.args
    arg_types = config.arg_types

    if map_size(args) != map_size(arg_types) do
      Logger.error(
        "gen_api, request, invalid number of arguments for #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
      )

      raise "invalid number of arguments for #{inspect(request.request_type)}"
    end

    config_args = MapSet.new(Map.keys(arg_types))
    request_args = MapSet.new(Map.keys(args))

    if !MapSet.equal?(config_args, request_args) do
      Logger.error(
        "gen_api, request, invalid arguments for #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
      )

      raise "invalid arguments for #{inspect(request.request_type)}"
    end

    # Verify argument types & values.
    Enum.each(args, fn {name, value} ->
      case arg_types[name] do
        :list ->
          if length(value) > @default_list_max_items do
            Logger.error(
              "gen_api, request, invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          arg_list_validation!(value)

        {:list, max_items} ->
          if length(value) > max_items do
            Logger.error(
              "gen_api, request, invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          arg_list_validation!(value)

        {:list_string, max_items, max_item_length} ->
          if length(value) > max_items do
            Logger.error(
              "gen_api, request, invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          if Enum.any?(value, fn item ->
               String.length(item) > max_item_length || not is_binary(item)
             end) do
            Logger.error(
              "gen_api, request, invalid argument item type/length for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument item type/length for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          arg_list_validation!(value)

        # TO-DO: Implement more for map type validation.
        :map ->
          if map_size(value) > @default_map_max_items do
            Logger.error(
              "gen_api, request, invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          arg_map_validation!(value)

        # TO-DO: Implement more for map type validation.
        {:map, max_items} ->
          if map_size(value) > max_items do
            Logger.error(
              "gen_api, request, invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
            )

            raise "invalid argument size for #{inspect(name)} in #{inspect(request.request_type)}"
          end

          arg_map_validation!(value)

        other ->
          arg_validation!(other, value)
      end
    end)
  end

  defp arg_map_validation!(value) when is_map(value) do
    Enum.each(value, fn {_key, val} ->
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
    Enum.each(value, fn item ->
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
          Logger.error("gen_api, request, unsupported type #{inspect(item)}")
          raise "unsupported type #{inspect(item)}"
      end
    end)
  end

  defp arg_list_validation!(value, fn_valid?) when is_list(value) do
    Enum.each(value, fn item ->
      if fn_valid?.(item) do
        :ok
      else
        Logger.error("gen_api, request, unsupported type #{inspect(item)} in list")
        raise "unsupported type of #{inspect(item)} in list"
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
        Logger.error("gen_api, request, invalid argument type for #{inspect(value)}")
        raise "invalid argument type for #{inspect(value)}"

      :boolean ->
        if value in [true, false] do
          :ok
        else
          Logger.error("gen_api, request, invalid argument type for #{inspect(value)}")
          raise "invalid argument type for #{inspect(value)}"
        end

      :num ->
        if is_float(value) or is_integer(value) do
          :ok
        else
          Logger.error("gen_api, request, invalid argument type for #{inspect(value)}")
          raise "invalid argument type for #{inspect(value)}"
        end

      :string ->
        if String.length(value) > @default_string_max_length do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

      {:string, max_length} ->
        if String.length(value) > max_length do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

      :list ->
        if length(value) > @default_list_max_items do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

        arg_list_validation!(value)

      :list_string ->
        if length(value) > @default_list_max_items do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

        arg_list_validation!(value, fn item ->
          is_binary(item) and String.length(item) < @default_string_max_length
        end)

      {:list_string, max_items, max_item_length} ->
        if length(value) > max_items do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

        arg_list_validation!(value, fn item ->
          is_binary(item) and String.length(item) < max_item_length
        end)

      :list_num ->
        if length(value) > @default_list_max_items do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

        arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)

      {:list_num, max_items} ->
        if length(value) > max_items do
          Logger.error("gen_api, request, invalid argument size for #{inspect(value)}")
          raise "invalid argument size for #{inspect(value)}"
        end

        arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)

      _ ->
        Logger.error("gen_api, request, unsupported type #{inspect(type)} for #{inspect(value)}")
        raise "unsupported type #{inspect(type)} for #{inspect(value)}"
    end
  end

  defp convert_arg!(arg, :string) when is_binary(arg) do
    arg
  end

  defp convert_arg!(arg, :boolean) when arg in [true, false] do
    arg
  end

  defp convert_arg!(arg, :num) when is_float(arg) or is_integer(arg) do
    arg
  end

  defp convert_arg!(arg, {:list_string, _, _}) when is_list(arg) do
    convert_arg!(arg, :list_string)
  end

  defp convert_arg!(arg, :list_string) when is_list(arg) do
    Enum.each(arg, fn
      x when is_binary(x) -> x
      x -> raise InvalidType, x
    end)

    arg
  end

  defp convert_arg!(arg, {:list_num, _}) do
    convert_arg!(arg, :list_num)
  end

  defp convert_arg!(arg, :list_num) when is_list(arg) do
    Enum.each(arg, fn
      x when is_float(x) or is_integer(x) -> x
      x -> raise InvalidType, x
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
    Logger.error("gen_api, request, unsupported type #{inspect(type)} for #{inspect(arg)}")
    raise InvalidType, message: "unsupported type #{inspect(type)} for #{inspect(arg)}"
  end
end
