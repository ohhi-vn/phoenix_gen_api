#!/usr/bin/env elixir

# Multi-node setup script for PhoenixGenApi benchmarking
#
# This script sets up a node for remote execution benchmarking.
# Run this script with: mix run scripts/setup_nodes.exs
#
# Usage:
#   1. Start the main node:
#      iex --name main@127.0.0.1 -S mix
#
#   2. In another terminal, start a worker node:
#      iex --name node2@127.0.0.1 -S mix
#
#   3. On the worker node, run this script:
#      mix run scripts/setup_nodes.exs
#
#   4. On the worker node, connect to main:
#      NodeSetup.connect_to_main(:"main@127.0.0.1")
#
#   5. On the main node, verify connection:
#      Node.list()  # Should show [:node2@127.0.0.1]
#
#   6. Run the benchmark:
#      mix run scripts/benchmark.exs -- --mode remote --concurrency 100 --requests 1000

alias PhoenixGenApi.{ConfigDb, Structs.FunConfig}

defmodule NodeSetup do
  @moduledoc """
  Helper module for setting up multi-node benchmarking.
  This module is loaded when you run: mix run scripts/setup_nodes.exs
  """

  def setup_worker_node() do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("PhoenixGenApi Worker Node Setup")
    IO.puts(String.duplicate("=", 60))

    case Node.self() do
      :nonode@nohost ->
        IO.puts("\n⚠️  This node is not distributed!")
        IO.puts("   Please start with: iex --name nodeX@127.0.0.1 -S mix")
        :error

      node_name ->
        IO.puts("\n✓ Node name: #{inspect(node_name)}")
        IO.puts("✓ Node alive: #{Node.alive?()}")

        # PhoenixGenApi should already be started by mix
        case Process.whereis(PhoenixGenApi) do
          nil ->
            IO.puts("\n⚠️  PhoenixGenApi not running!")
            IO.puts("   This script should be run with: mix run scripts/setup_nodes.exs")
            IO.puts("   Make sure you started with: iex --name nodeX -S mix")
            :error

          _pid ->
            IO.puts("\n✓ PhoenixGenApi already running")
            # Register test functions
            register_test_functions()

            IO.puts("\n" <> String.duplicate("-", 60))
            IO.puts("Worker node ready!")
            IO.puts(String.duplicate("-", 60))

            :ok
        end
    end
  end

  def connect_to_main(main_node) do
    IO.puts("\nConnecting to main node: #{inspect(main_node)}...")

    case Node.connect(main_node) do
      true ->
        IO.puts("✓ Connected to #{inspect(main_node)}")
        IO.puts("  Connected nodes: #{inspect(Node.list())}")
        :ok

      false ->
        IO.puts("✗ Failed to connect to #{inspect(main_node)}")
        IO.puts("  Make sure the main node is running and accessible")
        :error

      :ignored ->
        IO.puts("⚠️  Connection ignored (already connected or same node)")
        :ok
    end
  end

  def show_status() do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Node Status")
    IO.puts(String.duplicate("=", 60))
    IO.puts("Node name: #{inspect(Node.self())}")
    IO.puts("Alive: #{Node.alive?()}")
    IO.puts("Connected nodes: #{inspect(Node.list())}")

    case Process.whereis(PhoenixGenApi) do
      nil -> IO.puts("PhoenixGenApi: NOT RUNNING")
      pid -> IO.puts("PhoenixGenApi: Running (PID: #{inspect(pid)})")
    end

    IO.puts("\nConfigDb functions available:")
    IO.puts("  Use: PhoenixGenApi.ConfigDb.get_all_functions()")
    IO.puts(String.duplicate("=", 60))
  end

  defp register_test_functions() do
    IO.puts("\nRegistering test functions...")

    # Echo function for remote benchmarking
    echo_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service_remote",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 10_000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :sync
    }

    ConfigDb.add(echo_config)
    IO.puts("✓ Registered: echo (sync)")

    # Async echo function
    echo_async_config = %FunConfig{
      request_type: "echo",
      service: "benchmark_service_remote",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 10_000,
      mfa: {__MODULE__, :echo_handler, []},
      arg_types: %{"message" => :string},
      arg_orders: ["message"],
      response_type: :async
    }

    ConfigDb.add(echo_async_config)
    IO.puts("✓ Registered: echo (async)")
  end

  def echo_handler(%{"message" => message}) do
    {:ok, %{message: message, echo: true, node: node(), timestamp: DateTime.utc_now()}}
  end

  def echo_handler(args) when is_list(args) do
    args_map = Enum.into(args, %{})
    echo_handler(args_map)
  end
end

# Main execution - non-interactive setup
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("PhoenixGenApi Multi-Node Setup")
IO.puts(String.duplicate("=", 60))

# Auto-setup when script is run
NodeSetup.setup_worker_node()

IO.puts("""
#{String.duplicate("=", 60)}
Setup Complete!

Next steps:
1. Connect to main node (run on worker node):
   NodeSetup.connect_to_main(:"main@127.0.0.1")

2. Verify connection (optional):
   NodeSetup.show_status()

3. On main node, run benchmark:
   mix run scripts/benchmark.exs -- --mode remote
#{String.duplicate("=", 60)}
""")
