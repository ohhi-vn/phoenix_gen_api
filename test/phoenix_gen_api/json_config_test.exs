defmodule PhoenixGenApi.JsonConfigTest do
  use ExUnit.Case, async: false
  alias PhoenixGenApi.JsonConfig
  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.FunConfig

  setup do
    # Clear the config cache before each test
    ConfigDb.clear()
    :ok
  end

  describe "generate/2" do
    test "returns FunConfig structs by default" do
      # Add a test config
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      ConfigDb.add(config)

      result = JsonConfig.generate("chat")
      assert is_list(result)
      assert length(result) == 1
      assert [%FunConfig{request_type: "send_message"}] = result
    end

    test "returns map format when format: :map" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        version: "1.0.0",
        response_type: :sync
      }

      ConfigDb.add(config)

      result = JsonConfig.generate("chat", format: :map)
      assert is_map(result)

      # Check the key format
      result_list = Enum.to_list(result)
      assert length(result_list) == 1
      {"send_message - send_message", value} = hd(result_list)
      assert value["event"] == "phoenix_gen_api"
      assert value["data"]["request_type"] == "send_message"
      assert value["data"]["service"] == "chat"
      assert value["data"]["version"] == "1.0.0"
      assert value["data"]["args"] == %{"content" => ""}
    end

    test "returns JSON string when format: :json" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      ConfigDb.add(config)

      result = JsonConfig.generate("chat", format: :json)
      assert is_binary(result)

      # Parse it back to verify it's valid JSON
      {:ok, parsed} = JSON.decode(result)
      assert is_map(parsed)
    end

    test "supports custom descriptions as map" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      ConfigDb.add(config)

      result =
        JsonConfig.generate("chat",
          format: :map,
          descriptions: %{"send_message" => "Send a message to chat"}
        )

      result_list = Enum.to_list(result)
      assert length(result_list) == 1
      {"send_message - Send a message to chat", _} = hd(result_list)
    end

    test "supports custom descriptions as function" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      ConfigDb.add(config)

      result =
        JsonConfig.generate("chat",
          format: :map,
          descriptions: fn fun_config -> String.replace(fun_config.request_type, "_", " ") end
        )

      result_list = Enum.to_list(result)
      assert length(result_list) == 1
      {"send_message - send message", _} = hd(result_list)
    end

    test "supports custom arg values as map" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string, "to_user" => :string},
        arg_orders: ["content", "to_user"],
        response_type: :sync
      }

      ConfigDb.add(config)

      result =
        JsonConfig.generate("chat",
          format: :map,
          arg_values: %{
            "send_message" => %{"content" => "Hello!", "to_user" => "user_2"}
          }
        )

      result_list = Enum.to_list(result)
      assert length(result_list) == 1
      {_, value} = hd(result_list)
      assert value["data"]["args"] == %{"content" => "Hello!", "to_user" => "user_2"}
    end

    test "generates for all services with export_all/1" do
      config1 = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      config2 = %FunConfig{
        request_type: "get_users",
        service: "users",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :get_users, []},
        arg_types: nil,
        arg_orders: nil,
        response_type: :sync
      }

      ConfigDb.add(config1)
      ConfigDb.add(config2)

      result = JsonConfig.export_all(format: :map)
      assert map_size(result) == 2
    end

    test "generates for single service with export_service/2" do
      config1 = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      config2 = %FunConfig{
        request_type: "get_users",
        service: "users",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :get_users, []},
        arg_types: nil,
        arg_orders: nil,
        response_type: :sync
      }

      ConfigDb.add(config1)
      ConfigDb.add(config2)

      result = JsonConfig.export_service("chat", format: :map)
      assert map_size(result) == 1
      result_list = Enum.to_list(result)
      assert length(result_list) == 1
      {"send_message - send_message", _} = hd(result_list)
    end
  end

  describe "export_single/2" do
    test "exports a single FunConfig" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        version: "1.0.0",
        response_type: :sync
      }

      {key, value} = JsonConfig.export_single(config)

      assert key == "send_message - send_message"
      assert value["event"] == "phoenix_gen_api"
      assert value["data"]["request_type"] == "send_message"
      assert value["data"]["service"] == "chat"
      assert value["data"]["version"] == "1.0.0"
    end

    test "supports custom user_id and device_id" do
      config = %FunConfig{
        request_type: "send_message",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {MyModule, :send_message, []},
        arg_types: %{"content" => :string},
        arg_orders: ["content"],
        response_type: :sync
      }

      {_, value} =
        JsonConfig.export_single(config,
          user_id: "custom_user",
          device_id: "custom_device",
          request_id: "custom_request"
        )

      assert value["data"]["user_id"] == "custom_user"
      assert value["data"]["device_id"] == "custom_device"
      assert value["data"]["request_id"] == "custom_request"
    end
  end
end
