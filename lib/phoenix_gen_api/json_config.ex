defmodule PhoenixGenApi.JsonConfig do
  @moduledoc """
  Utility module for exporting %FunConfig{} to JSON format.

  This module provides functions to generate JSON configuration lists from
  PhoenixGenApi function configurations, supporting multiple output formats
  and customization options.

  ## JSON Config List Format

  The map format produces a structure like:

      %{
        "send_direct_message - Send direct message to other user" => %{
          "event" => "phoenix_gen_api",
          "data" => %{
            "user_id" => "user_1",
            "device_id" => "device_1",
            "request_type" => "send_direct_message",
            "request_id" => "request_1",
            "service" => "chat",
            "version" => "0.0.1",
            "args" => %{
              "to_user_id" => "",
              "content" => "",
              "reply_to_id" => ""
            }
          }
        }
      }

  ## Usage

      # Default: returns FunConfig structs (Ash Resource type)
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat)
      #=> [%PhoenixGenApi.Structs.FunConfig{...}, ...]

      # As Elixir map (JSON config list format)
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat, format: :map)
      #=> %{"send_direct_message - ..." => %{...}, ...}

      # As JSON string
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat, format: :json)
      #=> "{\\"send_direct_message - ...\\": {...}, ...}"

      # Custom encoder MFA
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat, format: {MyEncoder, :encode, []})

      # With custom descriptions
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat,
        format: :map,
        descriptions: %{"send_direct_message" => "Send direct message to other user"}
      )

      # With description function
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat,
        format: :map,
        descriptions: fn fun_config ->
          String.replace(fun_config.request_type, "_", " ")
        end
      )

      # With custom arg values
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat,
        format: :map,
        arg_values: %{
          "send_direct_message" => %{
            "to_user_id" => "user_2",
            "content" => "Hello, how are you?",
            "reply_to_id" => ""
          }
        }
      )

      # With arg values function
      PhoenixGenApi.JsonConfig.generate(MyApp.Chat,
        format: :map,
        arg_values: fn fun_config ->
          # Generate example values based on arg types
          fun_config.arg_types
          |> Enum.map(fn {name, type} -> {name, example_value(type)} end)
          |> Map.new()
        end
      )
  """

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.FunConfig

  @type format :: :structs | :map | :json | {module(), atom(), list()}
  @type description_source :: %{String.t() => String.t()} | (FunConfig.t() -> String.t()) | nil
  @type arg_values_source :: %{String.t() => map()} | (FunConfig.t() -> map()) | nil

  @doc """
  Generates JSON configuration from function configurations.

  ## Parameters

    - `service_or_services`: A service name (string/atom) or list of service names
    - `opts`: Options keyword list

  ## Options

    - `:format` - Output format (`:structs`, `:map`, `:json`, or `{module, function, args}`)
    - `:descriptions` - Custom descriptions (map or function)
    - `:arg_values` - Custom arg values (map or function)
    - `:user_id` - User ID for the request (default: "user_1")
    - `:device_id` - Device ID for the request (default: "device_1")
    - `:request_id` - Request ID for the request (default: "request_1")
    - `:event` - Event name (default: "phoenix_gen_api")

  ## Returns

    Depends on the `:format` option:
    - `:structs` - List of `%FunConfig{}` structs
    - `:map` - Map in JSON config list format
    - `:json` - JSON string
    - `{module, function, args}` - Result of calling the custom encoder
  """
  @spec generate(String.t() | atom() | [String.t() | atom()], keyword()) ::
          [FunConfig.t()] | map() | String.t() | any()
  def generate(service_or_services, opts \\ []) when is_list(opts) do
    fun_configs = fetch_fun_configs(service_or_services)
    format = Keyword.get(opts, :format, :structs)

    result =
      case format do
        :structs ->
          fun_configs

        :map ->
          fun_configs
          |> build_json_config_map(opts)
          |> maybe_add_descriptions(opts)
          |> maybe_add_arg_values(opts)

        :json ->
          fun_configs
          |> build_json_config_map(opts)
          |> maybe_add_descriptions(opts)
          |> maybe_add_arg_values(opts)
          |> JSON.encode!()

        {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
          config_map =
            fun_configs
            |> build_json_config_map(opts)
            |> maybe_add_descriptions(opts)
            |> maybe_add_arg_values(opts)

          apply(module, function, [config_map | args])

        other ->
          raise ArgumentError, "invalid format: #{inspect(other)}"
      end

    result
  end

  @doc """
  Exports a single %FunConfig{} to JSON config map format.

  ## Parameters

    - `fun_config`: A `%FunConfig{}` struct
    - `opts`: Options keyword list (same as `generate/2`)

  ## Returns

    A map in the JSON config format for a single function.
  """
  @spec export_single(FunConfig.t(), keyword()) :: {String.t(), map()}
  def export_single(fun_config = %FunConfig{}, opts \\ []) do
    user_id = Keyword.get(opts, :user_id, "user_1")
    device_id = Keyword.get(opts, :device_id, "device_1")
    request_id = Keyword.get(opts, :request_id, "request_1")
    event = Keyword.get(opts, :event, "phoenix_gen_api")

    key = build_key(fun_config, opts)
    value = build_config_value(fun_config, user_id, device_id, request_id, event, opts)

    {key, value}
  end

  @doc """
  Exports all functions from all services.

  ## Parameters

    - `opts`: Options keyword list (same as `generate/2`)

  ## Returns

    Same as `generate/2` but for all services.
  """
  @spec export_all(keyword()) :: [FunConfig.t()] | map() | String.t() | any()
  def export_all(opts \\ []) do
    generate(ConfigDb.get_all_services(), opts)
  end

  @doc """
  Exports functions from a specific service.

  ## Parameters

    - `service`: Service name (string or atom)
    - `opts`: Options keyword list (same as `generate/2`)

  ## Returns

    Same as `generate/2` for a single service.
  """
  @spec export_service(String.t() | atom(), keyword()) :: [FunConfig.t()] | map() | String.t() | any()
  def export_service(service, opts \\ []) when is_binary(service) or is_atom(service) do
    generate(service, opts)
  end

  # Private Functions

  defp fetch_fun_configs(service_or_services) do
    services =
      case service_or_services do
        service when is_binary(service) or is_atom(service) ->
          [service]

        services when is_list(services) ->
          services
      end

    ConfigDb.get_functions_from_services(services)
    |> Enum.flat_map(fn {service, request_types} ->
      Enum.flat_map(request_types, fn {request_type, versions} ->
        # Get the latest version for each request type
        latest_version = versions |> Enum.sort() |> List.last()
        case ConfigDb.get(service, request_type, latest_version) do
          {:ok, config = %FunConfig{}} -> [config]
          _ -> []
        end
      end)
    end)
  end

  defp build_json_config_map(fun_configs, opts) do
    fun_configs
    |> Enum.map(fn fun_config ->
      export_single(fun_config, opts)
    end)
    |> Map.new()
  end

  defp build_key(fun_config = %FunConfig{}, opts) do
    description = get_description(fun_config, opts)
    "#{fun_config.request_type} - #{description}"
  end

  defp build_config_value(fun_config = %FunConfig{}, user_id, device_id, request_id, event, opts) do
    %{
      "event" => event,
      "data" => %{
        "user_id" => user_id,
        "device_id" => device_id,
        "request_type" => fun_config.request_type,
        "request_id" => request_id,
        "service" => to_string(fun_config.service),
        "version" => fun_config.version,
        "args" => get_arg_values(fun_config, opts)
      }
    }
  end

  defp get_description(fun_config = %FunConfig{}, opts) do
    case Keyword.get(opts, :descriptions) do
      nil ->
        fun_config.request_type

      descriptions when is_map(descriptions) ->
        Map.get(descriptions, fun_config.request_type, fun_config.request_type)

      description_fn when is_function(description_fn, 1) ->
        description_fn.(fun_config)

      other ->
        raise ArgumentError, "invalid descriptions option: #{inspect(other)}"
    end
  end

  defp get_arg_values(fun_config = %FunConfig{}, opts) do
    case Keyword.get(opts, :arg_values) do
      nil ->
        build_default_args(fun_config)

      arg_values when is_map(arg_values) ->
        Map.get(arg_values, fun_config.request_type, build_default_args(fun_config))

      arg_values_fn when is_function(arg_values_fn, 1) ->
        arg_values_fn.(fun_config)

      other ->
        raise ArgumentError, "invalid arg_values option: #{inspect(other)}"
    end
  end

  defp build_default_args(%FunConfig{arg_types: nil}), do: %{}

  defp build_default_args(%FunConfig{arg_types: arg_types, arg_orders: arg_orders}) do
    case arg_orders do
      :map ->
        arg_types
        |> Enum.map(fn {name, _type} -> {name, ""} end)
        |> Map.new()

      orders when is_list(orders) ->
        orders
        |> Enum.map(fn name -> {name, ""} end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp maybe_add_descriptions(config_map, _opts) do
    # Descriptions are already included in the key
    config_map
  end

  defp maybe_add_arg_values(config_map, _opts) do
    # Arg values are already included in the config value
    config_map
  end
end
