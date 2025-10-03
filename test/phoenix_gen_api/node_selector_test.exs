defmodule PhoenixGenApi.NodeSelectorTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  setup do
    request = %Request{
      request_id: "test_request_id",
      request_type: "test_request",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"session_id" => "session_789"}
    }

    nodes = ["node1@localhost", "node2@localhost", "node3@localhost"]

    {:ok, request: request, nodes: nodes}
  end

  describe "get_node/2" do
    test "selects random node when mode is :random", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: :random
      }

      node = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "selects node using hash when mode is :hash", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: :hash
      }

      # Hash should be deterministic based on request_id
      node1 = NodeSelector.get_node(config, request)
      node2 = NodeSelector.get_node(config, request)

      assert node1 == node2
      assert node1 in nodes
    end

    test "selects node using hash with hash_key from args", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: {:hash, "session_id"}
      }

      node = NodeSelector.get_node(config, request)
      assert node in nodes

      # Same hash_key value should give same node
      node2 = NodeSelector.get_node(config, request)
      assert node == node2
    end

    test "selects node using hash with hash_key from request struct", %{nodes: nodes} do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"user_id" => "user_123"}
      }

      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: {:hash, "user_id"}
      }

      node = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "raises error when hash_key does not exist", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: {:hash, "nonexistent_key"}
      }

      assert_raise RuntimeError, ~r/hash_key/, fn ->
        NodeSelector.get_node(config, request)
      end
    end

    test "selects node using round_robin", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: :round_robin
      }

      # Get first node
      node1 = NodeSelector.get_node(config, request)
      assert node1 in nodes

      # Get second node (should be different in round robin)
      node2 = NodeSelector.get_node(config, request)
      assert node2 in nodes

      # Get third node
      node3 = NodeSelector.get_node(config, request)
      assert node3 in nodes

      # Fourth call should wrap around to first node
      node4 = NodeSelector.get_node(config, request)
      assert node4 == node1
    end

    test "handles single node for round_robin", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        nodes: ["single_node@localhost"],
        choose_node_mode: :round_robin
      }

      node1 = NodeSelector.get_node(config, request)
      node2 = NodeSelector.get_node(config, request)

      assert node1 == "single_node@localhost"
      assert node2 == "single_node@localhost"
    end

    test "handles dynamic nodes from MFA", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: {__MODULE__, :get_dynamic_nodes, []},
        choose_node_mode: :random
      }

      node = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "raises error when MFA returns invalid nodes", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        nodes: {__MODULE__, :get_invalid_nodes, []},
        choose_node_mode: :random
      }

      assert_raise RuntimeError, ~r/invalid nodes/, fn ->
        NodeSelector.get_node(config, request)
      end
    end
  end

  # Helper functions for dynamic nodes test
  def get_dynamic_nodes do
    ["node1@localhost", "node2@localhost", "node3@localhost"]
  end

  def get_invalid_nodes do
    "not_a_list"
  end
end
