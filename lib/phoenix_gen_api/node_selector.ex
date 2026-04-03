defmodule PhoenixGenApi.NodeSelector do
  @moduledoc """
  Provides node selection strategies for distributed request execution.

  This module implements various strategies for selecting a target node from a list of
  available nodes. The selection strategy determines how requests are distributed across
  nodes in a cluster.

  ## Supported Selection Strategies

  ### :random
  Selects a random node from the available nodes list. This provides simple load balancing
  with no guarantees about distribution fairness.

  ### :hash
  Uses consistent hashing based on the request ID to select a node. The same request ID
  will always map to the same node, which is useful for caching and stateful operations.

  ### {:hash, hash_key}
  Uses consistent hashing based on a specific field from the request. The `hash_key` can
  reference a field in `request.args` or a field directly on the request struct (like
  `user_id` or `device_id`). This ensures requests with the same hash_key value always
  go to the same node.

  ### :round_robin
  Distributes requests evenly across all nodes in a circular fashion. Each process maintains
  its own round-robin counter in the process dictionary.

  ## Dynamic Node Resolution

  Instead of a static list of nodes, you can provide a module-function-args tuple that
  will be called at runtime to get the current list of nodes:

      nodes: {MyApp.NodeRegistry, :get_active_nodes, []}

  This allows for dynamic node discovery and automatic adaptation to cluster changes.

  ## Fault Tolerance

  - Nodes are validated before selection
  - Empty node lists return `{:error, :no_nodes_available}`
  - Invalid node formats are filtered out
  - Failed node resolution is logged with details

  ## Examples

      # Random selection
      config = %FunConfig{
        nodes: ["node1@host", "node2@host", "node3@host"],
        choose_node_mode: :random
      }
      {:ok, node} = NodeSelector.get_node(config, request)

      # Hash by request ID (consistent)
      config = %FunConfig{
        nodes: ["node1@host", "node2@host"],
        choose_node_mode: :hash
      }
      {:ok, node} = NodeSelector.get_node(config, request)
      # Same request ID will always return same node

      # Hash by custom field
      request = %Request{
        request_id: "req_123",
        user_id: "user_456",
        args: %{"session_id" => "sess_789"}
      }

      # Hash by user_id
      config = %FunConfig{
        nodes: ["node1@host", "node2@host"],
        choose_node_mode: {:hash, "user_id"}
      }
      {:ok, node} = NodeSelector.get_node(config, request)
      # All requests from same user go to same node

      # Round-robin
      config = %FunConfig{
        nodes: ["node1@host", "node2@host", "node3@host"],
        choose_node_mode: :round_robin
      }
      {:ok, node1} = NodeSelector.get_node(config, request)  # node1@host
      {:ok, node2} = NodeSelector.get_node(config, request)  # node2@host
      {:ok, node3} = NodeSelector.get_node(config, request)  # node3@host
      {:ok, node4} = NodeSelector.get_node(config, request)  # node1@host (wraps around)

  ## Notes

  - Round-robin state is maintained per process using the process dictionary
  - Hash functions use `:erlang.phash2/2` for deterministic hashing
  - Dynamic node resolution happens on every call, allowing real-time cluster updates
  - If a hash_key is not found in the request, falls back to random selection
  - Returns `{:ok, node}` on success or `{:error, reason}` on failure
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  require Logger

  @doc """
  Selects a target node based on the configuration and request.

  This function examines the `choose_node_mode` in the configuration and applies
  the appropriate node selection strategy. If the `nodes` field is a tuple, it
  will be called as a function to dynamically resolve the node list.

  ## Parameters

    - `config` - A `FunConfig` struct containing:
      - `nodes` - Either a list of node names or a `{module, function, args}` tuple
      - `choose_node_mode` - The selection strategy (`:random`, `:hash`, `{:hash, key}`, `:round_robin`)

    - `request` - A `Request` struct containing the request details

  ## Returns

  The selected node name as a string (e.g., `"node1@hostname"`).

  ## Raises

  - `RuntimeError` - If the MFA returns an invalid nodes list
  - `RuntimeError` - If a hash_key is specified but not found in the request

  ## Examples

      config = %FunConfig{
        nodes: ["node1@host", "node2@host"],
        choose_node_mode: :random
      }

      request = %Request{
        request_id: "req_123",
        request_type: "get_user",
        user_id: "user_456",
        args: %{"user_id" => "user_456"}
      }

      node = NodeSelector.get_node(config, request)
      # => "node1@host" or "node2@host"
  """
  def get_node(config = %FunConfig{nodes: {m, f, a}}, request = %Request{}) do
    case resolve_dynamic_nodes(m, f, a) do
      {:ok, nodes} ->
        config = %{config | nodes: nodes}
        get_node(config, request)

      {:error, reason} ->
        Logger.error("PhoenixGenApi.NodeSelector, get_node, failed to resolve dynamic nodes: #{inspect(reason)}")
        {:error, {:dynamic_node_resolution_failed, reason}}
    end
  end

  def get_node(config = %FunConfig{}, request = %Request{}) do
    nodes = validate_nodes(config.nodes)

    if nodes == [] do
      Logger.error("PhoenixGenApi.NodeSelector, get_node, no valid nodes available")
      {:error, :no_nodes_available}
    else
      config = %{config | nodes: nodes}
      select_node(config, request)
    end
  end

  defp resolve_dynamic_nodes(m, f, a) when is_atom(m) and is_atom(f) and is_list(a) do
    try do
      case apply(m, f, a) do
        nodes when is_list(nodes) ->
          {:ok, nodes}

        other ->
          {:error, {:invalid_return_type, other}}
      end
    rescue
      error ->
        {:error, {:exception, Exception.message(error)}}
    catch
      kind, value ->
        {:error, {kind, value}}
    end
  end

  defp resolve_dynamic_nodes(_, _, _) do
    {:error, :invalid_mfa_format}
  end

  defp validate_nodes(nodes) when is_list(nodes) do
    Enum.filter(nodes, &is_valid_node?/1)
  end

  defp validate_nodes(_), do: []

  defp is_valid_node?(node) when is_atom(node), do: true
  defp is_valid_node?(node) when is_binary(node), do: true
  defp is_valid_node?(_), do: false

  defp select_node(config, request) do
    case config.choose_node_mode do
      :random ->
        {:ok, Enum.random(config.nodes)}

      :hash ->
        {:ok, hash_node(request, config)}

      {:hash, hash_key} ->
        hash_node_with_fallback(request, config, hash_key)

      :round_robin ->
        {:ok, round_robin_node(request, config)}

      _ ->
        Logger.error("PhoenixGenApi.NodeSelector, invalid choose_node_mode: #{inspect(config.choose_node_mode)}")
        {:error, {:invalid_choose_node_mode, config.choose_node_mode}}
    end
  end

  def choose_node_valid?(config = %FunConfig{}) do
    case config.choose_node_mode do
      :random -> true
      :hash -> true
      {:hash, _} -> true
      :round_robin -> true
      _ -> false
    end
  end

  defp hash_node(request, config) do
    hash_order = :erlang.phash2(request.request_id, length(config.nodes))
    Enum.at(config.nodes, hash_order)
  end

  defp hash_node_with_fallback(request, config, hash_key) do
    value =
      Map.get(request.args, hash_key) ||
        Map.get(request, hash_key)

    case value do
      nil ->
        Logger.warning(
          "PhoenixGenApi.NodeSelector, hash key #{inspect(hash_key)} not found in request, falling back to random"
        )

        {:ok, Enum.random(config.nodes)}

      val ->
        hash_order = :erlang.phash2(val, length(config.nodes))
        {:ok, Enum.at(config.nodes, hash_order)}
    end
  end

  defp round_robin_node(_request, config) do
    node_num = config.nodes |> length() |> next_round_robin_node_num()
    Enum.at(config.nodes, node_num)
  end

  defp next_round_robin_node_num(1) do
    0
  end

  defp next_round_robin_node_num(nodes_length) do
    case Process.get(:phoenix_gen_api_round_robin_num, nil) do
      nil ->
        Process.put(:phoenix_gen_api_round_robin_num, 0)
        0

      curr_num ->
        next_num = rem(curr_num + 1, nodes_length)
        Process.put(:phoenix_gen_api_round_robin_num, next_num)
        next_num
    end
  end
end
