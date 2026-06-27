defmodule PhoenixGenApi.NodeSelectorNodesTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.NodeSelector
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  describe "get_nodes/2 with random mode" do
    test "returns a list with all nodes" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_1",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, selected_nodes} = NodeSelector.get_nodes(config, request)
      assert length(selected_nodes) == 3
      Enum.each(selected_nodes, fn node -> assert node in nodes end)
    end

    test "returns all nodes in some order" do
      nodes = [:node1@host, :node2@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_2",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, selected_nodes} = NodeSelector.get_nodes(config, request)
      assert length(selected_nodes) == 2
    end
  end

  describe "get_nodes/2 with hash mode" do
    test "returns deterministic node list based on request_id" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: :hash
      }

      request = %Request{
        request_id: "req_deterministic",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, nodes1} = NodeSelector.get_nodes(config, request)
      assert {:ok, nodes2} = NodeSelector.get_nodes(config, request)
      assert nodes1 == nodes2
    end

    test "primary node is consistent for same hash key" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: {:hash, "session_id"}
      }

      request = %Request{
        request_id: "req_1",
        user_id: "user_123",
        service: "test_service",
        request_type: "test",
        args: %{"session_id" => "session_abc"}
      }

      assert {:ok, [primary | _]} = NodeSelector.get_nodes(config, request)

      # Same session_id should give same primary
      request2 = %{request | request_id: "req_2"}
      assert {:ok, [primary2 | _]} = NodeSelector.get_nodes(config, request2)
      assert primary == primary2
    end
  end

  describe "get_nodes/2 with round_robin mode" do
    test "returns all nodes with round robin ordering" do
      nodes = [:node1@host, :node2@host, :node3@host]

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: nodes,
        choose_node_mode: :round_robin
      }

      request = %Request{
        request_id: "req_rr",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, selected_nodes} = NodeSelector.get_nodes(config, request)
      assert length(selected_nodes) == 3
      # All nodes should be present
      assert Enum.sort(selected_nodes) == Enum.sort(nodes)
    end
  end

  describe "get_nodes/2 with single node" do
    test "returns single node list" do
      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: [:only_node@host],
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_single",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:ok, [:only_node@host]} = NodeSelector.get_nodes(config, request)
    end
  end

  describe "get_nodes/2 error cases" do
    test "returns error when nodes list is empty" do
      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: [],
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_err",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:error, :no_nodes_available} = NodeSelector.get_nodes(config, request)
    end

    test "returns error when dynamic nodes MFA returns invalid" do
      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: {__MODULE__, :invalid_nodes, []},
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_dyn_err",
        user_id: "user_123",
        service: "test_service",
        request_type: "test"
      }

      assert {:error, {:dynamic_node_resolution_failed, _}} =
               NodeSelector.get_nodes(config, request)
    end
  end

  def invalid_nodes do
    "not_a_list"
  end
end
