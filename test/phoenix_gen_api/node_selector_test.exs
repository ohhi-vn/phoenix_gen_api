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

      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "selects node using hash when mode is :hash", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: :hash
      }

      # Hash should be deterministic based on request_id
      assert {:ok, node1} = NodeSelector.get_node(config, request)
      assert {:ok, node2} = NodeSelector.get_node(config, request)

      assert node1 == node2
      assert node1 in nodes
    end

    test "selects node using hash with hash_key from args", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: {:hash, "session_id"}
      }

      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes

      # Same hash_key value should give same node
      assert {:ok, node2} = NodeSelector.get_node(config, request)
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

      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "falls back to random when hash_key does not exist", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: {:hash, "nonexistent_key"}
      }

      # Should fall back to random selection instead of raising
      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "selects node using round_robin", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: nodes,
        choose_node_mode: :round_robin
      }

      # Get first node
      assert {:ok, node1} = NodeSelector.get_node(config, request)
      assert node1 in nodes

      # Get second node (should be different in round robin)
      assert {:ok, node2} = NodeSelector.get_node(config, request)
      assert node2 in nodes

      # Get third node
      assert {:ok, node3} = NodeSelector.get_node(config, request)
      assert node3 in nodes

      # Fourth call should wrap around to first node
      assert {:ok, node4} = NodeSelector.get_node(config, request)
      assert node4 == node1
    end

    test "handles single node for round_robin", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        nodes: ["single_node@localhost"],
        choose_node_mode: :round_robin
      }

      assert {:ok, node1} = NodeSelector.get_node(config, request)
      assert {:ok, node2} = NodeSelector.get_node(config, request)

      assert node1 == "single_node@localhost"
      assert node2 == "single_node@localhost"
    end

    test "handles dynamic nodes from MFA", %{request: request, nodes: nodes} do
      config = %FunConfig{
        request_type: "test",
        nodes: {__MODULE__, :get_dynamic_nodes, []},
        choose_node_mode: :random
      }

      assert {:ok, node} = NodeSelector.get_node(config, request)
      assert node in nodes
    end

    test "returns error when MFA returns invalid nodes", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        nodes: {__MODULE__, :get_invalid_nodes, []},
        choose_node_mode: :random
      }

      assert {:error, {:dynamic_node_resolution_failed, _}} =
               NodeSelector.get_node(config, request)
    end

    test "returns error when nodes list is empty", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        nodes: [],
        choose_node_mode: :random
      }

      assert {:error, :no_nodes_available} = NodeSelector.get_node(config, request)
    end
  end

  # Helper functions for dynamic nodes test
  def get_dynamic_nodes do
    ["node1@localhost", "node2@localhost", "node3@localhost"]
  end

  def get_invalid_nodes do
    "not_a_list"
  end

  def get_raising_nodes do
    raise "boom"
  end

  def get_throwing_nodes do
    throw(:caught)
  end

  describe "resolve_nodes/1 and resolve_nodes_list/1" do
    test "resolve_nodes/1 with :local, list and invalid nodes" do
      assert {:ok, %FunConfig{nodes: :local}} =
               NodeSelector.resolve_nodes(%FunConfig{nodes: :local})

      nodes = ["node1@localhost", "node2@localhost"]

      assert {:ok, %FunConfig{nodes: ^nodes}} =
               NodeSelector.resolve_nodes(%FunConfig{nodes: nodes})

      assert {:error, {:invalid_nodes_configuration, :bogus}} =
               NodeSelector.resolve_nodes(%FunConfig{nodes: :bogus})
    end

    test "resolve_nodes/1 with a dynamic MFA that raises or throws" do
      assert {:error, {:dynamic_node_resolution_failed, {:exception, "boom"}}} =
               NodeSelector.resolve_nodes(%FunConfig{nodes: {__MODULE__, :get_raising_nodes, []}})

      assert {:error, {:dynamic_node_resolution_failed, {:throw, :caught}}} =
               NodeSelector.resolve_nodes(%FunConfig{
                 nodes: {__MODULE__, :get_throwing_nodes, []}
               })
    end

    test "resolve_nodes/1 with a malformed dynamic MFA" do
      assert {:error, {:dynamic_node_resolution_failed, :invalid_mfa_format}} =
               NodeSelector.resolve_nodes(%FunConfig{nodes: {String, :upcase, :not_a_list}})
    end

    test "resolve_nodes_list/1 with :local" do
      assert {:ok, [local]} = NodeSelector.resolve_nodes_list(%FunConfig{nodes: :local})
      assert local == Node.self()
    end

    test "resolve_nodes_list/1 propagates resolution errors" do
      assert {:error, {:invalid_nodes_configuration, :bogus}} =
               NodeSelector.resolve_nodes_list(%FunConfig{nodes: :bogus})
    end
  end

  describe "choose_node_valid?/1" do
    test "returns true for all supported modes" do
      assert NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: :random})
      assert NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: :hash})
      assert NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: {:hash, "k"}})
      assert NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: :round_robin})
      assert NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: {:sticky, "k"}})
    end

    test "returns false for unsupported modes" do
      refute NodeSelector.choose_node_valid?(%FunConfig{choose_node_mode: :bogus})
    end
  end

  describe "get_node/2 with invalid choose_node_mode" do
    test "returns an error" do
      config = %FunConfig{
        nodes: ["node1@localhost"],
        choose_node_mode: :bogus,
        request_type: "x"
      }

      assert {:error, {:invalid_choose_node_mode, :bogus}} =
               NodeSelector.get_node(config, %Request{request_id: "r"})
    end
  end

  describe "get_nodes/2 with invalid choose_node_mode" do
    test "returns an error" do
      config = %FunConfig{
        nodes: ["node1@localhost"],
        choose_node_mode: :bogus,
        request_type: "x"
      }

      assert {:error, {:invalid_choose_node_mode, :bogus}} =
               NodeSelector.get_nodes(config, %Request{request_id: "r"})
    end
  end

  describe "calculate_backoff/2" do
    test "with jitter disabled returns deterministic capped delay" do
      assert NodeSelector.calculate_backoff(1, jitter: false) == 100
      assert NodeSelector.calculate_backoff(20, jitter: false, base_ms: 100, max_ms: 500) == 500
    end
  end

  describe "reset_round_robin/0" do
    test "returns :ok when the counter table does not exist yet" do
      assert :ok = NodeSelector.reset_round_robin()
    end

    test "returns :ok after the counter table exists" do
      config = %FunConfig{
        nodes: ["node1@localhost", "node2@localhost"],
        choose_node_mode: :round_robin
      }

      assert {:ok, _node} = NodeSelector.get_node(config, %Request{request_id: "r"})
      assert :ok = NodeSelector.reset_round_robin()
    end
  end
end
