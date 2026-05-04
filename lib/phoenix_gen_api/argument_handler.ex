defmodule PhoenixGenApi.ArgumentHandler do
  @moduledoc """
  Validates and converts request arguments according to configured type specifications.

  This module provides comprehensive argument validation and type conversion for API requests.
  It ensures that all request arguments match their expected types and sizes before function
  execution, preventing type errors and potential security issues.

  ## Argument Type Definitions

  ### Simple Format (Backward Compatible)

  The simple format uses just the type atom:

      arg_types: %{
        "user_id" => :string,
        "age" => :num,
        "active" => :boolean
      }

  ### Extended Format (New)

  The extended format uses a keyword list with `:type` and optional parameters:

      arg_types: %{
        "user_id" => [type: :string, max_bytes: 255, allow_nil?: true],
        "age" => [type: :num, default_value: 18],
        "tags" => [type: :list_string, max_items: 10, max_item_bytes: 100],
        "scores" => [type: :list_num, max_items: 50],
        "metadata" => [type: :map, max_items: 200]
      }

  #### Extended Format Options

  - `type:` - Required. The argument type (`:string`, `:num`, `:boolean`, etc.)
  - `allow_nil?:` - Optional. When `true`, allows nil values (default: `false`)
  - `default_value:` - Optional. Default value if argument is missing from request
  - `max_bytes:` - For `:string` type, max byte size
  - `max_items:` - For list/map types, max number of items
  - `max_item_bytes:` - For `:list_string`, max bytes per item

  #### Behavior

  - If argument is **missing** from request and `default_value` is set -> uses default_value
  - If argument is **missing** from request and no `default_value` -> error (unless `allow_nil?`)
  - If argument is **explicitly nil** and `allow_nil?` is true -> uses nil
  - If argument is **explicitly nil** and `allow_nil?` is false -> error
  - If argument is **present** -> validates and converts the value

  ### Type-Specific Parameters

  - **`:string`**: `max_bytes:` (default 3000)
  - **`:list`**: `max_items:` (default 1000)
  - **`:list_string`**: `max_items:` (default 1000), `max_item_bytes:` (default 3000)
  - **`:list_num`**: `max_items:` (default 1000)
  - **`:map`**: `max_items:` (default 1000)

  ## Size Limits (Defaults)

  - Strings: 3000 bytes (not characters, to prevent UTF-8 bypass attacks)
  - Lists: 1000 items
  - Maps: 1000 entries

  These limits help prevent denial-of-service attacks through oversized payloads.

  ## Security Considerations

  - Uses `byte_size/1` instead of `String.length/1` to prevent UTF-8 bypass attacks
  - Validates against oversized payloads that could cause memory exhaustion
  - Rejects nested structures to prevent deep recursion attacks
  - Strict type checking prevents type confusion vulnerabilities

  ## Validation Rules

  1. **Type Matching**: Argument values must match their declared types
  2. **Size Limits**: Strings, lists, and maps must not exceed size limits
  3. **Required Arguments**: All declared arguments must be present
  4. **No Extra Arguments**: Requests cannot include undeclared arguments
  5. **No Nil Values**: Nil values are not accepted for any argument
  6. **No Nesting**: Nested lists and maps are not currently supported

  ## Examples

      # Configure argument types (simple format)
      config = %FunConfig{
        arg_types: %{
          "username" => :string,
          "age" => :num,
          "email" => :string,
          "tags" => :list_string,
          "scores" => :list_num
        },
        arg_orders: ["username", "age", "email", "tags", "scores"]
      }

      # Configure argument types (extended format with nil and default support)
      config = %FunConfig{
        arg_types: %{
          "username" => [type: :string, allow_nil?: false],
          "age" => [type: :num, default_value: 18],
          "email" => [type: :string, allow_nil?: true, max_bytes: 255],
          "tags" => [type: :list_string, default_value: [], max_items: 10, max_item_bytes: 100],
          "scores" => [type: :list_num, allow_nil?: true, max_items: 100]
        },
        arg_orders: ["username", "age", "email", "tags", "scores"]
      }

      # When allow_nil? is true, nil values are accepted
      # When default_value is set and argument is missing, default is used
      # If argument is missing and no default_value, and allow_nil? is false -> error
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
      # ** (ArgumentError) invalid argument type for "age": expected :num, got "thirty"

  ## Error Handling

  All validation functions raise `ArgumentError` on validation failures with descriptive
  messages. The `InvalidType` exception is raised for type conversion errors.

  ## Notes

  - Argument order is preserved based on `arg_orders` configuration
  - Functions with no arguments return an empty list
  - Single-argument functions return a list with one element
  - Validation happens before type conversion
  - Nested structures (maps in maps, lists in lists) are not supported
  - `arg_types` can be in simple format (`%{"user_id" => :string}`) or extended format
    (`%{"user_id" => [type: :string, allow_nil?: true, default_value: "hello"]}`).
  """

  ## Helper Functions for Extended arg_types Format

  # Extract type parameters for complex types
  defp get_type_with_params(type) when not is_list(type) and not is_tuple(type), do: {type, []}

  # Handle old tuple format: {:list_num, 2}
  defp get_type_with_params({type, value}) when is_atom(type) do
    # Convert old tuple format to keyword list
    params =
      case type do
        :string -> [max_bytes: value]
        :list -> [max_items: value]
        :list_string -> [max_items: value]
        :list_num -> [max_items: value]
        :map -> [max_items: value]
        _ -> []
      end

    {type, params}
  end

  defp get_type_with_params(arg_config) when is_list(arg_config) do
    type = Keyword.get(arg_config, :type)
    params = Keyword.drop(arg_config, [:type, :allow_nil?, :default_value])
    {type, params}
  end

  # Build the type with params for convert_arg!
  defp build_type_with_params(type, []), do: type

  defp build_type_with_params(:string, params) do
    max_bytes = Keyword.get(params, :max_bytes, string_max_bytes())
    {:string, [max_bytes: max_bytes]}
  end

  defp build_type_with_params(:list, params) do
    max_items = Keyword.get(params, :max_items, list_max_items())
    {:list, [max_items: max_items]}
  end

  defp build_type_with_params(:list_string, params) do
    max_items = Keyword.get(params, :max_items, list_max_items())
    max_item_bytes = Keyword.get(params, :max_item_bytes, string_max_bytes())
    {:list_string, [max_items: max_items, max_item_bytes: max_item_bytes]}
  end

  defp build_type_with_params(:list_num, params) do
    max_items = Keyword.get(params, :max_items, list_max_items())
    {:list_num, [max_items: max_items]}
  end

  defp build_type_with_params(:map, params) do
    max_items = Keyword.get(params, :max_items, map_max_items())
    {:map, [max_items: max_items]}
  end

  defp build_type_with_params(:uuid, _params) do
    # UUID type doesn't have additional params currently, but we accept params for consistency
    {:uuid, []}
  end

  defp build_type_with_params(:list_uuid, params) do
    max_items = Keyword.get(params, :max_items, list_max_items())
    {:list_uuid, [max_items: max_items]}
  end

  defp build_type_with_params(type, _params), do: type

  # Helper functions for extracting allow_nil? and default_value
  defp get_allow_nil_from_arg_config(arg_config) when is_list(arg_config) do
    Keyword.get(arg_config, :allow_nil?, false)
  end

  defp get_allow_nil_from_arg_config(_), do: false

  defp get_default_value_from_arg_config(arg_config) when is_list(arg_config) do
    Keyword.get(arg_config, :default_value, nil)
  end

  defp get_default_value_from_arg_config(_), do: nil

  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.Errors.InvalidType

  require Logger

  # Size limits are now configurable via application env:
  #   config :phoenix_gen_api, :argument_handler,
  #     string_max_bytes: 3000,
  #     list_max_items: 1000,
  #     map_max_items: 1000
  #
  # Fallback defaults are used when not configured.
  @default_string_max_bytes 3000
  @default_list_max_items 1000
  @default_map_max_items 1000

  @doc """
  Returns the configured maximum string size in bytes.

  Configurable via `config :phoenix_gen_api, :argument_handler, string_max_bytes: N`.
  Defaults to #{@default_string_max_bytes}.
  """
  def string_max_bytes do
    Application.get_env(:phoenix_gen_api, :argument_handler, [])[:string_max_bytes] ||
      @default_string_max_bytes
  end

  @doc """
  Returns the configured maximum number of items in a list.

  Configurable via `config :phoenix_gen_api, :argument_handler, list_max_items: N`.
  Defaults to #{@default_list_max_items}.
  """
  def list_max_items do
    Application.get_env(:phoenix_gen_api, :argument_handler, [])[:list_max_items] ||
      @default_list_max_items
  end

  @doc """
  Returns the configured maximum number of items in a map.

  Configurable via `config :phoenix_gen_api, :argument_handler, map_max_items: N`.
  Defaults to #{@default_map_max_items}.
  """
  def map_max_items do
    Application.get_env(:phoenix_gen_api, :argument_handler, [])[:map_max_items] ||
      @default_map_max_items
  end

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

      # Simple format
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{
        args: %{"name" => "Alice", "age" => 30}
      }

      ArgumentHandler.convert_args!(config, request)
      # => ["Alice", 30]

      # Extended format with default values
      config = %FunConfig{
        arg_types: %{
          "name" => [type: :string],
          "age" => [type: :num, default_value: 25],
          "email" => [type: :string, allow_nil?: true]
        },
        arg_orders: ["name", "age", "email"]
      }

      # Missing "age" and "email" - will use default for age, nil for email
      request = %Request{
        args: %{"name" => "Bob"}
      }

      ArgumentHandler.convert_args!(config, request)
      # => ["Bob", 25, nil]
  """
  def convert_args!(config = %FunConfig{}, request = %Request{}) do
    validate_args!(config, request)

    args = request.args || %{}
    arg_types = config.arg_types || %{}

    # Build the final arguments map with default values and type conversion
    converted_args =
      Enum.reduce(arg_types, %{}, fn {name, arg_config}, acc ->
        {type, params} = get_type_with_params(arg_config)
        allow_nil = get_allow_nil_from_arg_config(arg_config)
        default_value = get_default_value_from_arg_config(arg_config)

        # Check if argument is present in request (even if nil)
        arg_present = Map.has_key?(args, name)

        value =
          if arg_present do
            # Argument is present in request (could be nil)
            Map.get(args, name)
          else
            # Argument is missing from request
            if default_value != nil do
              default_value
            else
              nil
            end
          end

        # Handle nil value
        final_value =
          if value == nil and not allow_nil do
            nil
          else
            value
          end

        # Convert the argument with proper type handling
        converted_value =
          if final_value == nil and allow_nil do
            nil
          else
            # Build the type with params for convert_arg!
            type_with_params = build_type_with_params(type, params)
            convert_arg!(final_value, type_with_params)
          end

        Map.put(acc, name, converted_value)
      end)

    cond do
      # function has no arguments.
      arg_types == nil or map_size(arg_types) == 0 ->
        []

      # arg_orders is :map, return a map instead of a list.
      config.arg_orders == :map ->
        [converted_args]

      # function has only one argument.
      map_size(arg_types) == 1 ->
        Map.values(converted_args)

      # function has multiple arguments.
      true ->
        result =
          Enum.reduce(config.arg_orders, [], fn name, acc ->
            case Map.get(converted_args, name) do
              nil ->
                # Check if this is allowed (allow_nil? or default_value)
                arg_config = Map.get(arg_types, name)
                allow_nil = get_allow_nil_from_arg_config(arg_config)
                default_value = get_default_value_from_arg_config(arg_config)

                if allow_nil or default_value != nil do
                  [nil | acc]
                else
                  Logger.error(
                    "PhoenixGenApi.ArgumentHandler, missing argument #{inspect(name)} in #{inspect(request.request_type)}"
                  )

                  raise ArgumentError,
                        "missing argument #{inspect(name)} in #{inspect(request.request_type)}"
                end

              arg ->
                [arg | acc]
            end
          end)
          |> Enum.reverse()

        Logger.debug("PhoenixGenApi.ArgumentHandler, converted args: #{inspect(result)}")
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
    args = request.args || %{}
    arg_types = config.arg_types || %{}

    check_extra_args!(args, arg_types, request.request_type, request.request_id)
    validate_all_args!(arg_types, args, config, request)
    :ok
  end

  defp check_extra_args!(args, arg_types, request_type, request_id) do
    request_args_set = MapSet.new(Map.keys(args))
    config_args_set = MapSet.new(Map.keys(arg_types))

    extra_args = MapSet.difference(request_args_set, config_args_set)

    unless Enum.empty?(extra_args) do
      Logger.error(
        "PhoenixGenApi.ArgumentHandler, extra arguments for #{inspect(request_type)}, request_id: #{inspect(request_id)}, extra: #{inspect(extra_args)}"
      )

      raise ArgumentError,
            "extra arguments for #{inspect(request_type)}, extra: #{inspect(MapSet.to_list(extra_args))}"
    end
  end

  defp validate_all_args!(arg_types, args, _config, request) do
    Enum.each(arg_types, fn {name, arg_config} ->
      {type, params} = get_type_with_params(arg_config)
      allow_nil = get_allow_nil_from_arg_config(arg_config)
      default_value = get_default_value_from_arg_config(arg_config)

      value = get_argument_value(name, args, default_value)
      validate_arg!(name, type, params, value, allow_nil, request)
    end)
  end

  defp get_argument_value(name, args, default_value) do
    if Map.has_key?(args, name) do
      Map.get(args, name)
    else
      default_value
    end
  end

  defp validate_arg!(name, type, params, value, allow_nil, request) do
    if value == nil and not allow_nil do
      Logger.error(
        "PhoenixGenApi.ArgumentHandler, missing or nil argument #{inspect(name)} in #{inspect(request.request_type)}, request_id: #{inspect(request.request_id)}"
      )

      raise ArgumentError,
            "missing or nil argument #{inspect(name)} in #{inspect(request.request_type)}"
    else
      # If value is nil and allow_nil is true, skip validation
      unless value == nil and allow_nil do
        type_with_params = build_type_with_params(type, params)
        arg_validation!(type_with_params, value, name, request)
      end
    end
  end

  defp arg_map_validation!(value) when is_map(value) do
    Enum.each(value, fn {key, val} ->
      cond do
        is_boolean(val) ->
          :ok

        is_float(val) or is_integer(val) ->
          :ok

        is_binary(val) ->
          if byte_size(val) > string_max_bytes() do
            Logger.error(
              "PhoenixGenApi.ArgumentHandler, nested map string value exceeds max byte size for key #{inspect(key)}"
            )

            raise ArgumentError,
                  "nested map string value exceeds max byte size for key #{inspect(key)}"
          end

        is_list(val) ->
          if length(val) > list_max_items() do
            Logger.error(
              "PhoenixGenApi.ArgumentHandler, nested map list value exceeds max items for key #{inspect(key)}"
            )

            raise ArgumentError,
                  "nested map list value exceeds max items for key #{inspect(key)}"
          end

          arg_list_validation!(val)

        is_map(val) ->
          Logger.error("PhoenixGenApi.ArgumentHandler, nested map is not supported yet")
          raise ArgumentError, "nested map is not supported yet"

        true ->
          Logger.error(
            "PhoenixGenApi.ArgumentHandler, unsupported type #{inspect(val)} in map for key #{inspect(key)}"
          )

          raise ArgumentError, "unsupported type #{inspect(val)} in map for key #{inspect(key)}"
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
          if byte_size(item) > string_max_bytes() do
            Logger.error(
              "PhoenixGenApi.ArgumentHandler, string item in list exceeds max byte size"
            )

            raise ArgumentError, "string item in list exceeds max byte size"
          end

        is_map(item) ->
          Logger.error("PhoenixGenApi.ArgumentHandler, nested map is not supported yet")
          raise ArgumentError, "nested map is not supported yet"

        is_list(item) ->
          Logger.error("PhoenixGenApi.ArgumentHandler, nested list is not supported yet")
          raise ArgumentError, "nested list is not supported yet"

        true ->
          Logger.error("PhoenixGenApi.ArgumentHandler, unsupported type #{inspect(item)}")
          raise ArgumentError, "unsupported type #{inspect(item)}"
      end
    end)
  end

  defp arg_list_validation!(value, fn_valid?) when is_list(value) do
    Enum.each(value, fn item ->
      if fn_valid?.(item) do
        :ok
      else
        Logger.error("PhoenixGenApi.ArgumentHandler, unsupported type #{inspect(item)} in list")
        raise "unsupported type of #{inspect(item)} in list"
      end
    end)
  end

  defp arg_validation!(_type, nil, name, _request) do
    # This function is called when value is nil
    # The allow_nil? check should have been done in validate_args! and convert_args!
    # If we reach here with nil, it means allow_nil? is false
    Logger.error(
      "PhoenixGenApi.ArgumentHandler, nil value not accepted for argument #{inspect(name)}"
    )

    raise ArgumentError, "nil value not accepted for argument #{inspect(name)}"
  end

  defp arg_validation!(type, value, name, request) do
    case type do
      nil ->
        log_and_raise("unknown type for argument #{inspect(name)}")

      type when is_atom(type) ->
        validate_simple_type!(type, value, name, request)

      {type, params} when is_atom(type) ->
        validate_complex_type!(type, params, value, name, request)

      _ ->
        log_and_raise("unsupported type #{inspect(type)} for argument #{inspect(name)}")
    end
  end

  defp validate_simple_type!(:boolean, value, name, _request) do
    validate_boolean!(value, name)
  end

  defp validate_simple_type!(:datetime, value, name, _request) do
    validate_string_type!(value, name, :datetime)
  end

  defp validate_simple_type!(:naive_datetime, value, name, _request) do
    validate_string_type!(value, name, :naive_datetime)
  end

  defp validate_simple_type!(:num, value, name, _request) do
    validate_num!(value, name)
  end

  defp validate_simple_type!(:string, value, name, _request) do
    validate_string_size!(value, name, string_max_bytes())
  end

  defp validate_simple_type!(:uuid, value, name, _request) do
    validate_uuid!(value, name)
  end

  defp validate_simple_type!(:map, value, name, request) do
    validate_map_size!(name, value, map_max_items(), request.request_type, request.request_id)
  end

  defp validate_simple_type!(:list, value, name, request) do
    validate_list_size!(name, value, list_max_items(), request.request_type, request.request_id)
    arg_list_validation!(value)
  end

  defp validate_simple_type!(:list_string, value, name, request) do
    validate_list_size!(name, value, list_max_items(), request.request_type, request.request_id)

    arg_list_validation!(value, fn item ->
      is_binary(item) and byte_size(item) <= string_max_bytes()
    end)
  end

  defp validate_simple_type!(:list_num, value, name, request) do
    validate_list_size!(name, value, list_max_items(), request.request_type, request.request_id)
    arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)
  end

  defp validate_simple_type!(:list_uuid, value, name, request) do
    validate_list_size!(name, value, list_max_items(), request.request_type, request.request_id)

    arg_list_validation!(value, fn item ->
      is_binary(item) and Uniq.UUID.valid?(item)
    end)
  end

  defp validate_complex_type!(:string, [max_bytes: max_bytes], value, name, _request) do
    validate_string_size!(value, name, max_bytes)
  end

  defp validate_complex_type!(:list, [max_items: max_items], value, name, request) do
    validate_list_size!(name, value, max_items, request.request_type, request.request_id)
    arg_list_validation!(value)
  end

  defp validate_complex_type!(
         :list_string,
         [max_items: max_items, max_item_bytes: max_item_bytes],
         value,
         name,
         request
       ) do
    validate_list_size!(name, value, max_items, request.request_type, request.request_id)

    arg_list_validation!(value, fn item ->
      is_binary(item) and byte_size(item) <= max_item_bytes
    end)
  end

  defp validate_complex_type!(:list_num, [max_items: max_items], value, name, request) do
    validate_list_size!(name, value, max_items, request.request_type, request.request_id)
    arg_list_validation!(value, fn item -> is_float(item) or is_integer(item) end)
  end

  defp validate_complex_type!(:list_uuid, [max_items: max_items], value, name, request) do
    validate_list_size!(name, value, max_items, request.request_type, request.request_id)

    arg_list_validation!(value, fn item ->
      is_binary(item) and Uniq.UUID.valid?(item)
    end)
  end

  defp validate_complex_type!(:map, [max_items: max_items], value, name, request) do
    validate_map_size!(name, value, max_items, request.request_type, request.request_id)
    arg_map_validation!(value)
  end

  defp validate_boolean!(value, name) do
    if value in [true, false],
      do: :ok,
      else:
        log_and_raise(
          "invalid argument type for #{inspect(name)}, expected :boolean, got #{inspect(value)}"
        )
  end

  defp validate_string_type!(value, name, type) do
    if is_binary(value),
      do: :ok,
      else:
        log_and_raise(
          "invalid argument type for #{inspect(name)}, expected :#{type} (ISO 8601 string), got #{inspect(value)}"
        )
  end

  defp validate_num!(value, name) do
    if is_float(value) or is_integer(value),
      do: :ok,
      else:
        log_and_raise(
          "invalid argument type for #{inspect(name)}, expected :num, got #{inspect(value)}"
        )
  end

  defp validate_string_size!(value, name, max_bytes) do
    if byte_size(value) > max_bytes do
      log_and_raise("invalid argument size for #{inspect(name)}, max #{max_bytes} bytes")
    end
  end

  defp validate_uuid!(value, name) do
    if not Uniq.UUID.valid?(value) do
      log_and_raise("invalid argument value for #{inspect(name)}, require a UUID format string")
    end
  end

  defp log_and_raise(message) do
    Logger.error("PhoenixGenApi.ArgumentHandler, " <> message)
    raise ArgumentError, message
  end

  defp validate_list_size!(name, value, max_items, request_type, request_id) do
    if length(value) > max_items do
      Logger.error(
        "PhoenixGenApi.ArgumentHandler, invalid argument size for #{inspect(name)} in #{inspect(request_type)}, request_id: #{inspect(request_id)}"
      )

      raise ArgumentError,
            "invalid argument size for #{inspect(name)} in #{inspect(request_type)}, max #{max_items} items"
    end
  end

  defp validate_map_size!(name, value, max_items, request_type, request_id) do
    if map_size(value) > max_items do
      Logger.error(
        "PhoenixGenApi.ArgumentHandler, invalid argument size for #{inspect(name)} in #{inspect(request_type)}, request_id: #{inspect(request_id)}"
      )

      raise ArgumentError,
            "invalid argument size for #{inspect(name)} in #{inspect(request_type)}, max #{max_items} items"
    end
  end

  defp convert_arg!(arg, :string) when is_binary(arg) do
    if byte_size(arg) > string_max_bytes() do
      raise ArgumentError, "string argument exceeds max byte size of #{string_max_bytes()}"
    end

    arg
  end

  defp convert_arg!(arg, {:string, [max_bytes: max_bytes]}) when is_binary(arg) do
    if byte_size(arg) > max_bytes do
      raise ArgumentError, "string argument exceeds max byte size of #{max_bytes}"
    end

    arg
  end

  defp convert_arg!(arg, :boolean) when is_boolean(arg), do: arg

  defp convert_arg!(arg, :datetime) when is_binary(arg) do
    case DateTime.from_iso8601(arg) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError, "invalid datetime format for #{inspect(arg)}: #{reason}"
    end
  end

  defp convert_arg!(arg, :naive_datetime) when is_binary(arg) do
    case NaiveDateTime.from_iso8601(arg) do
      {:ok, naive_datetime} ->
        naive_datetime

      {:error, reason} ->
        raise ArgumentError, "invalid naive_datetime format for #{inspect(arg)}: #{reason}"
    end
  end

  defp convert_arg!(arg, :uuid) when is_binary(arg) do
    if Uniq.UUID.valid?(arg) do
      arg
    else
      raise InvalidType, arg
    end
  end

  defp convert_arg!(arg, :num) when is_number(arg) do
    arg
  end

  defp convert_arg!(arg, {:list_string, [max_items: max_items, max_item_bytes: max_item_bytes]})
       when is_list(arg) do
    if length(arg) > max_items do
      raise ArgumentError, "list_string argument exceeds max items of #{max_items}"
    end

    Enum.each(arg, fn
      item when is_binary(item) ->
        if byte_size(item) > max_item_bytes do
          raise ArgumentError,
                "string item in list_string exceeds max byte size of #{max_item_bytes}"
        end

      item ->
        raise InvalidType, item
    end)

    arg
  end

  defp convert_arg!(arg, :list_string) when is_list(arg) do
    if length(arg) > list_max_items() do
      raise ArgumentError, "list_string argument exceeds max items of #{list_max_items()}"
    end

    Enum.each(arg, fn
      item when is_binary(item) ->
        if byte_size(item) > string_max_bytes() do
          raise ArgumentError,
                "string item in list_string exceeds max byte size of #{string_max_bytes()}"
        end

      item ->
        raise InvalidType, item
    end)

    arg
  end

  defp convert_arg!(arg, {:list_num, [max_items: max_items]}) when is_list(arg) do
    if length(arg) > max_items do
      raise ArgumentError, "list_num argument exceeds max items of #{max_items}"
    end

    Enum.each(arg, fn
      x when is_number(x) -> x
      x -> raise InvalidType, x
    end)

    arg
  end

  defp convert_arg!(arg, :list_num) when is_list(arg) do
    if length(arg) > list_max_items() do
      raise ArgumentError, "list_num argument exceeds max items of #{list_max_items()}"
    end

    Enum.each(arg, fn
      x when is_number(x) -> x
      x -> raise InvalidType, x
    end)

    arg
  end

  defp convert_arg!(arg, {:list, [max_items: max_items]}) when is_list(arg) do
    if length(arg) > max_items do
      raise ArgumentError, "list argument exceeds max items of #{max_items}"
    end

    arg
  end

  defp convert_arg!(arg, :list) when is_list(arg) do
    if length(arg) > list_max_items() do
      raise ArgumentError, "list argument exceeds max items of #{list_max_items()}"
    end

    arg
  end

  defp convert_arg!(arg, {:map, [max_items: max_items]}) when is_map(arg) do
    if map_size(arg) > max_items do
      raise ArgumentError, "map argument exceeds max items of #{max_items}"
    end

    arg
  end

  defp convert_arg!(arg, :map) when is_map(arg) do
    if map_size(arg) > map_max_items() do
      raise ArgumentError, "map argument exceeds max items of #{map_max_items()}"
    end

    arg
  end

  defp convert_arg!(arg, {:list_uuid, [max_items: max_items]}) when is_list(arg) do
    if length(arg) > max_items do
      raise ArgumentError, "list_uuid argument exceeds max items of #{max_items}"
    end

    Enum.each(arg, fn x ->
      if is_binary(x) and Uniq.UUID.valid?(x) do
        x
      else
        raise InvalidType, x
      end
    end)

    arg
  end

  defp convert_arg!(arg, :list_uuid) when is_list(arg) do
    if length(arg) > list_max_items() do
      raise ArgumentError, "list_uuid argument exceeds max items of #{list_max_items()}"
    end

    Enum.each(arg, fn x ->
      if is_binary(x) and Uniq.UUID.valid?(x) do
        x
      else
        raise InvalidType, x
      end
    end)

    arg
  end

  defp convert_arg!(_arg, type) do
    Logger.error("PhoenixGenApi.ArgumentHandler, unsupported type #{inspect(type)} for argument")
    raise InvalidType, message: "unsupported type #{inspect(type)}"
  end
end
