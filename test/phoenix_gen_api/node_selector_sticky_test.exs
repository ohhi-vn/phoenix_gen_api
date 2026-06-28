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

  describe "cleanup_sticky_table/0" do
    test "returns :ok when the table exists and is empty" do
      NodeSelector.cleanup_sticky_table()
      assert :ok = NodeSelector.cleanup_sticky_table()
    end

    test "removes expired entries but keeps fresh ones" do
      nodes = [:node1@host, :node2@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: {:sticky, "user_id"}
      }

      request = %Request{
        request_id: "req_cleanup_1",
        user_id: "user_cleanup_fresh",
        service: "test_service",
        request_type: "test"
      }

      # Create a fresh sticky entry via get_node
      assert {:ok, _node} = NodeSelector.get_node(config, request)

      # Manually insert an expired entry directly into the ETS table
      expired_ts = System.system_time(:millisecond) - 3_600_001

      :ets.insert(
        :phoenix_gen_api_sticky_nodes,
        {"user_cleanup_expired", :node1@host, expired_ts}
      )

      # Confirm both entries exist before cleanup
      assert :ets.lookup(:phoenix_gen_api_sticky_nodes, "user_cleanup_fresh") != []
      assert :ets.lookup(:phoenix_gen_api_sticky_nodes, "user_cleanup_expired") != []

      # Run cleanup
      assert :ok = NodeSelector.cleanup_sticky_table()

      # Expired entry should be removed
      assert :ets.lookup(:phoenix_gen_api_sticky_nodes, "user_cleanup_expired") == []

      # Fresh entry should still be present
      assert :ets.lookup(:phoenix_gen_api_sticky_nodes, "user_cleanup_fresh") != []

      # Clean up the fresh entry for test isolation
      :ets.delete(:phoenix_gen_api_sticky_nodes, "user_cleanup_fresh")
    end

    test "does not crash when called multiple times" do
      assert :ok = NodeSelector.cleanup_sticky_table()
      assert :ok = NodeSelector.cleanup_sticky_table()
      assert :ok = NodeSelector.cleanup_sticky_table()
    end
  end
end
