defmodule PhoenixGenApi.Structs.ServiceConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.ServiceConfig

  describe "from_map/1" do
    test "decodes valid service config map" do
      config_map = %{
        "service" => "test_service",
        "nodes" => ["node1@localhost", "node2@localhost"],
        "module" => "TestModule",
        "function" => "test_function",
        "args" => [1, 2, 3]
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "test_service"
      assert config.nodes == ["node1@localhost", "node2@localhost"]
      assert config.module == "TestModule"
      assert config.function == "test_function"
      assert config.args == [1, 2, 3]
    end

    test "handles atom keys" do
      config_map = %{
        service: "test_service",
        nodes: ["node1@localhost"],
        module: "TestModule",
        function: "test_function",
        args: []
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "test_service"
      assert config.nodes == ["node1@localhost"]
    end
  end
end
