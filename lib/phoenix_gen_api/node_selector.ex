defmodule PhoenixGenApi.NodeSelector do
  @moduledoc """
  Provides node selection strategies for distributed request execution.

  This module implements various strategies for selecting target nodes from a list of
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
  Distributes requests evenly across all nodes in a circular fashion. Uses an atomic
  counter for true global round-robin distribution across all processes.

  ## Dynamic Node Resolution

  Instead of a static list of nodes, you can provide a module-function-args tuple that
  will be called at runtime to get the current list of nodes:

      nodes: {MyApp.NodeRegistry, :get_active_nodes, []}

  This allows for dynamic node discovery and automatic adaptation to cluster changes.

  ## Node Selection for Retry/Fallback

  The `get_nodes/2` function returns a list of nodes suitable for the retry strategy:

  - `:random` and `:hash` return a single-node list (the selected node)
  - `:round_robin` returns all nodes (for fallback to other nodes on failure)

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

      # Hash by custom field
      request = %Request{
        request_id: "req_123",
        user_id: "user_456",
        args: %{"session_id" => "sess_789"}
      }

      config = %FunConfig{
        nodes: ["node1@host", "node2@host"],
        choose_node_mode: {:hash, "user_id"}
      }
      {:ok, node} = NodeSelector.get_node(config, request)

      # Round-robin (global, atomic counter)
      config = %FunConfig{
        nodes: ["node1@host", "node2@host", "node3@host"],
        choose_node_mode: :round_robin
      }
      {:ok, node1} = NodeSelector.get_node(config, request)
      {:ok, node2} = NodeSelector.get_node(config, request)
      {:ok, node3} = NodeSelector.get_node(config, request)
      {:ok, node1_again} = NodeSelector.get_node(config, request)  # wraps around

  ## Notes

  - Round-robin uses an atomic counter for true global distribution (no process dictionary)
  - Hash functions use `:erlang.phash2/2` for deterministic hashing
  - Dynamic node resolution happens on every call, allowing real-time cluster updates
  - If a hash_key is not found in the request, falls back to random selection
  - Returns `{:ok, node}` on success or `{:error, reason}` on failure
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.Helpers.Shared

  require Logger

  # Atomic counter reference for round-robin. Initialized lazily.
  @round_robin_counter_name :phoenix_gen_api_round_robin_counter

  @doc """
  Selects a single target node based on the configuration and request.

  This function examines the `choose_node_mode` in the configuration and applies
  the appropriate node selection strategy. If the `nodes` field is a tuple, it
  will be called as a function to dynamically resolve the node list.

  ## Parameters

    - `config` - A `FunConfig` struct containing:
      - `nodes` - Either a list of node names or a `{module, function, args}` tuple
      - `choose_node_mode` - The selection strategy (`:random`, `:hash`, `{:hash, key}`, `:round_robin`)

    - `request` - A `Request` struct containing the request details

  ## Returns

    - `{:ok, node}` - The selected node
    - `{:error, reason}` - Selection failed

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

      {:ok, node} = NodeSelector.get_node(config, request)
  """
  @spec get_node(FunConfig.t(), Request.t()) ::
          {:ok, node :: atom() | String.t()} | {:error, term()}
  def get_node(config = %FunConfig{}, request = %Request{}) do
    with {:ok, resolved_config} <- resolve_nodes(config),
         {:ok, nodes} <- validate_and_get_nodes(resolved_config) do
      select_node(nodes, resolved_config.choose_node_mode, request)
    end
  end

  @doc """
  Selects a list of target nodes based on the configuration and request.

  The returned list is ordered by preference for fallback/retry purposes:

  - `:random` - Returns a shuffled list of all nodes (selected node first)
  - `:hash` / `{:hash, key}` - Returns all nodes with the hashed node first
  - `:round_robin` - Returns all nodes starting from the round-robin position

  This is useful for the executor's fallback mechanism where if the primary
  node fails, it tries the remaining nodes in order.

  ## Parameters

    - `config` - A `FunConfig` struct
    - `request` - A `Request` struct

  ## Returns

    - `{:ok, [node, ...]}` - Ordered list of nodes (primary first)
    - `{:error, reason}` - Selection failed

  ## Examples

      config = %FunConfig{
        nodes: ["node1@host", "node2@host", "node3@host"],
        choose_node_mode: :random
      }

      {:ok, [primary | fallbacks]} = NodeSelector.get_nodes(config, request)
  """
  @spec get_nodes(FunConfig.t(), Request.t()) :: {:ok, [atom() | String.t()]} | {:error, term()}
  def get_nodes(config = %FunConfig{}, request = %Request{}) do
    with {:ok, resolved_config} <- resolve_nodes(config),
         {:ok, nodes} <- validate_and_get_nodes(resolved_config) do
      select_nodes_ordered(nodes, resolved_config.choose_node_mode, request)
    end
  end

  @doc """
  Resolves dynamic node configuration to a concrete node list.

  If `nodes` is an MFA tuple `{module, function, args}`, calls the function
  to get the node list at runtime. If `nodes` is already a list, returns
  the config unchanged. If `nodes` is `:local`, returns the config unchanged.

  ## Parameters

    - `config` - A `FunConfig` struct

  ## Returns

    - `{:ok, %FunConfig{}}` - Config with resolved nodes
    - `{:error, reason}` - Resolution failed
  """
  @spec resolve_nodes(FunConfig.t()) :: {:ok, FunConfig.t()} | {:error, term()}
  def resolve_nodes(config = %FunConfig{nodes: :local}), do: {:ok, config}
  def resolve_nodes(config = %FunConfig{nodes: nodes}) when is_list(nodes), do: {:ok, config}

  def resolve_nodes(config = %FunConfig{nodes: {m, f, a}}) do
    case resolve_dynamic_nodes(m, f, a) do
      {:ok, nodes} ->
        {:ok, %{config | nodes: nodes}}

      {:error, reason} ->
        Logger.error(
          "PhoenixGenApi.NodeSelector, resolve_nodes, failed to resolve dynamic nodes: #{inspect(reason)}"
        )

        {:error, {:dynamic_node_resolution_failed, reason}}
    end
  end

  def resolve_nodes(%FunConfig{nodes: other}) do
    Logger.error(
      "PhoenixGenApi.NodeSelector, resolve_nodes, invalid nodes configuration: #{inspect(other)}"
    )

    {:error, {:invalid_nodes_configuration, other}}
  end

  @doc """
  Resolves nodes and returns the raw node list regardless of configuration type.

  Unlike `resolve_nodes/1` which returns the full config, this returns just
  the list of nodes. Useful for getting all available nodes for retry strategies.

  ## Parameters

    - `config` - A `FunConfig` struct

  ## Returns

    - `{:ok, [node]}` - List of resolved nodes
    - `{:error, reason}` - Resolution failed
  """
  @spec resolve_nodes_list(FunConfig.t()) :: {:ok, [atom() | String.t()]} | {:error, term()}
  def resolve_nodes_list(%FunConfig{nodes: :local}) do
    {:ok, [node()]}
  end

  def resolve_nodes_list(%FunConfig{} = config) do
    case resolve_nodes(config) do
      {:ok, resolved} -> {:ok, Shared.validate_nodes(resolved.nodes)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates that the `choose_node_mode` is a recognized strategy.

  ## Returns

    - `true` if the mode is valid
    - `false` otherwise
  """
  @spec choose_node_valid?(FunConfig.t()) :: boolean()
  def choose_node_valid?(%FunConfig{choose_node_mode: mode}) do
    case mode do
      :random -> true
      :hash -> true
      {:hash, _} -> true
      :round_robin -> true
      _ -> false
    end
  end

  @doc """
  Calculates a retry backoff delay based on the attempt number.

  Uses exponential backoff with jitter to prevent thundering herd problems.

  ## Parameters

    - `attempt` - The current attempt number (1-based)
    - `opts` - Options keyword list:
      - `:base_ms` - Base delay in milliseconds (default: 100)
      - `:max_ms` - Maximum delay in milliseconds (default: 5000)
      - `:jitter` - Whether to add random jitter (default: true)

  ## Returns

    - Delay in milliseconds before the next retry

  ## Examples

      iex> NodeSelector.calculate_backoff(1)
      # Returns ~100ms (with jitter)

      iex> NodeSelector.calculate_backoff(3)
      # Returns ~400ms (with jitter)

      iex> NodeSelector.calculate_backoff(5, max_ms: 2000)
      # Returns capped at ~2000ms (with jitter)
  """
  @spec calculate_backoff(pos_integer(), keyword()) :: non_neg_integer()
  def calculate_backoff(attempt, opts \\ []) when is_integer(attempt) and attempt > 0 do
    base_ms = Keyword.get(opts, :base_ms, 100)
    max_ms = Keyword.get(opts, :max_ms, 5_000)
    jitter? = Keyword.get(opts, :jitter, true)

    # Exponential backoff: base * 2^(attempt-1)
    delay = (base_ms * :math.pow(2, attempt - 1)) |> trunc()
    delay = min(delay, max_ms)

    if jitter? do
      # Add random jitter: 0.5x to 1.5x the delay
      jitter_factor = 0.5 + :rand.uniform()
      trunc(delay * jitter_factor)
    else
      delay
    end
  end

  @doc """
  Resets the round-robin counter.

  This is primarily useful for testing. In production, the counter
  should be allowed to increment naturally.
  """
  @spec reset_round_robin() :: :ok
  def reset_round_robin do
    case :ets.whereis(@round_robin_counter_name) do
      :undefined -> :ok
      table -> :ets.insert(table, {:counter, 0})
    end

    :ok
  end

  # --- Private Functions ---

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

  defp validate_and_get_nodes(%FunConfig{nodes: :local}) do
    {:ok, [node()]}
  end

  defp validate_and_get_nodes(%FunConfig{nodes: nodes}) do
    validated = Shared.validate_nodes(nodes)

    if validated == [] do
      Logger.error("PhoenixGenApi.NodeSelector, no valid nodes available")
      {:error, :no_nodes_available}
    else
      {:ok, validated}
    end
  end

  # Select a single node (backward compatible with get_node/2)
  defp select_node(nodes, mode, request) do
    case mode do
      :random ->
        {:ok, Enum.random(nodes)}

      :hash ->
        {:ok, hash_node(request, nodes)}

      {:hash, hash_key} ->
        hash_node_with_fallback(request, nodes, hash_key)

      :round_robin ->
        {:ok, round_robin_node(nodes)}

      _ ->
        Logger.error("PhoenixGenApi.NodeSelector, invalid choose_node_mode: #{inspect(mode)}")

        {:error, {:invalid_choose_node_mode, mode}}
    end
  end

  # Select an ordered list of nodes (primary first, then fallbacks)
  defp select_nodes_ordered(nodes, mode, request) do
    case mode do
      :random ->
        # Shuffle nodes, putting a random one first
        primary = Enum.random(nodes)
        fallbacks = List.delete(nodes, primary) |> Enum.shuffle()
        {:ok, [primary | fallbacks]}

      :hash ->
        primary = hash_node(request, nodes)
        fallbacks = List.delete(nodes, primary)
        {:ok, [primary | fallbacks]}

      {:hash, hash_key} ->
        # hash_node_with_fallback always returns {:ok, node} (falling back to random on miss)
        primary = hash_node_with_fallback(request, nodes, hash_key)
        fallbacks = List.delete(nodes, primary)
        {:ok, [primary | fallbacks]}

      :round_robin ->
        # Return all nodes starting from the round-robin position
        primary_idx = get_round_robin_index(length(nodes))
        {before, after_nodes} = Enum.split(nodes, primary_idx)
        {:ok, after_nodes ++ before}

      _ ->
        Logger.error("PhoenixGenApi.NodeSelector, invalid choose_node_mode: #{inspect(mode)}")

        {:error, {:invalid_choose_node_mode, mode}}
    end
  end

  defp hash_node(request, nodes) do
    hash_order = :erlang.phash2(request.request_id, length(nodes))
    Enum.at(nodes, hash_order)
  end

  defp hash_node_with_fallback(request, nodes, hash_key) do
    value =
      Map.get(request.args, hash_key) ||
        case request do
          %{^hash_key => v} when not is_nil(v) -> v
          _ -> nil
        end

    case value do
      nil ->
        Logger.warning(
          "PhoenixGenApi.NodeSelector, hash key #{inspect(hash_key)} not found in request, falling back to random"
        )

        Enum.random(nodes)

      val ->
        hash_order = :erlang.phash2(val, length(nodes))
        Enum.at(nodes, hash_order)
    end
  end

  # Round-robin using an atomic counter stored in ETS.
  # This provides true global round-robin across all processes,
  # unlike the previous process dictionary approach.
  defp round_robin_node(nodes) do
    nodes_length = length(nodes)
    idx = get_round_robin_index(nodes_length)
    Enum.at(nodes, idx)
  end

  defp get_round_robin_index(nodes_length) when nodes_length <= 1, do: 0

  defp get_round_robin_index(nodes_length) do
    ensure_round_robin_table()

    # Atomically increment and get the next index
    # Use :ets.update_counter for atomic increment
    try do
      counter =
        :ets.update_counter(
          @round_robin_counter_name,
          :counter,
          {2, 1},
          {@round_robin_counter_name, 0}
        )

      rem(counter, nodes_length)
    rescue
      ArgumentError ->
        # Table might have been recreated; retry once
        ensure_round_robin_table()

        counter =
          :ets.update_counter(
            @round_robin_counter_name,
            :counter,
            {2, 1},
            {@round_robin_counter_name, 0}
          )

        rem(counter, nodes_length)
    end
  end

  defp ensure_round_robin_table do
    case :ets.whereis(@round_robin_counter_name) do
      :undefined ->
        try do
          :ets.new(@round_robin_counter_name, [
            :named_table,
            :public,
            :set,
            write_concurrency: true
          ])

          :ets.insert(@round_robin_counter_name, {:counter, 0})
        rescue
          ArgumentError ->
            # Table was created by another process concurrently; that's fine
            :ok
        end

      _ ->
        :ok
    end
  end
end
