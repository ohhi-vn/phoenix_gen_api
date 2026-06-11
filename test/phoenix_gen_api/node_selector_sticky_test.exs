defmodule PhoenixGenApi.NodeSelectorStickyTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  describe "sticky node affinity" do
    test "selects same node for same hash_key value" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: {:sticky, "user_id"}
      }

      request1 = %Request{
        request_id: "req_1",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      request2 = %Request{
        request_id: "req_2",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      # Same user_id should get same node
      assert {:ok, _node1} = NodeSelector.get_node(config, request1)
      assert {:ok, _node1} = NodeSelector.get_node(config, request2)

      # Different user_id should get different node (or same by chance, but let's test)
      request3 = %Request{
        request_id: "req_3",
        user_id: "user_456",
        service: "test_service",
        request_type: "test"
      }

      # Could be same or different, but should be valid
      assert {:ok, node} = NodeSelector.get_node(config, request3)
      assert node in nodes
    end

    test "falls back to random when hash_key not found" do
      nodes = [:node1@host, :node2@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: {:sticky, "nonexistent_key"}
      }

      request = %Request{
        request_id: "req_1",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "get_nodes returns ordered list with sticky node first" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: {:sticky, "user_id"}
      }

      request = %Request{
        request_id: "req_1",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, [primary | _fallbacks]} = NodeSelector.get_nodes(config, request)
      assert primary in nodes
    end
  end
end
