defmodule PhoenixGenApi.RelayServer do
  @moduledoc """
  Serializes all relay group ETS operations to prevent race conditions.

  Owns the ETS table (`:phoenix_gen_api_relay_groups`) and processes all
  group mutations sequentially via `GenServer.call/3`. Because a GenServer
  handles one message at a time, the read-modify-write patterns in
  `PhoenixGenApi.Relay` execute atomically with respect to each other.
  """

  use GenServer, restart: :permanent

  alias PhoenixGenApi.Relay

  require Logger

  @table :phoenix_gen_api_relay_groups

  # ── Client API ─────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the ETS table name (for backward compatibility)."
  @spec table :: atom()
  def table, do: @table

  def create_group(group_id, group_type, creator_user_id, channel_pid) do
    GenServer.call(
      __MODULE__,
      {:create_group, group_id, group_type, creator_user_id, channel_pid}
    )
  end

  def delete_group(group_id) do
    GenServer.call(__MODULE__, {:delete_group, group_id})
  end

  def get_group_info(group_id) do
    GenServer.call(__MODULE__, {:get_group_info, group_id})
  end

  def join_group(group_id, user_id, channel_pid) do
    GenServer.call(__MODULE__, {:join_group, group_id, user_id, channel_pid})
  end

  def leave_group(group_id, user_id) do
    GenServer.call(__MODULE__, {:leave_group, group_id, user_id})
  end

  def accept_member(group_id, actor_user_id, target_user_id) do
    GenServer.call(__MODULE__, {:accept_member, group_id, actor_user_id, target_user_id})
  end

  def mute_member(group_id, actor_user_id, target_user_id) do
    GenServer.call(__MODULE__, {:mute_member, group_id, actor_user_id, target_user_id})
  end

  def unmute_member(group_id, actor_user_id, target_user_id) do
    GenServer.call(__MODULE__, {:unmute_member, group_id, actor_user_id, target_user_id})
  end

  def handle_relay(request, fun_config) do
    GenServer.call(__MODULE__, {:handle_relay, request, fun_config})
  end

  # ── Server Callbacks ───────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("[RelayServer] initialized ETS table with read/write concurrency")
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call(
        {:create_group, group_id, group_type, creator_user_id, channel_pid},
        _from,
        state
      ) do
    result = Relay.do_create_group(group_id, group_type, creator_user_id, channel_pid)
    {:reply, result, state}
  end

  def handle_call({:delete_group, group_id}, _from, state) do
    result = Relay.do_delete_group(group_id)
    {:reply, result, state}
  end

  def handle_call({:get_group_info, group_id}, _from, state) do
    result = Relay.do_get_group_info(group_id)
    {:reply, result, state}
  end

  def handle_call({:join_group, group_id, user_id, channel_pid}, _from, state) do
    result = Relay.do_join_group(group_id, user_id, channel_pid)

    case result do
      {:ok, _} ->
        ref = Process.monitor(channel_pid)
        new_monitors = Map.put(state.monitors, {group_id, user_id}, ref)
        {:reply, result, %{state | monitors: new_monitors}}

      _ ->
        {:reply, result, state}
    end
  end

  def handle_call({:leave_group, group_id, user_id}, _from, state) do
    result = Relay.do_leave_group(group_id, user_id)

    case result do
      :ok ->
        new_monitors =
          case Map.pop(state.monitors, {group_id, user_id}) do
            {nil, monitors} ->
              monitors

            {ref, monitors} ->
              Process.demonitor(ref, [:flush])
              monitors
          end

        {:reply, result, %{state | monitors: new_monitors}}

      _ ->
        {:reply, result, state}
    end
  end

  def handle_call({:accept_member, group_id, actor_user_id, target_user_id}, _from, state) do
    result = Relay.do_accept_member(group_id, actor_user_id, target_user_id)
    {:reply, result, state}
  end

  def handle_call({:mute_member, group_id, actor_user_id, target_user_id}, _from, state) do
    result = Relay.do_mute_member(group_id, actor_user_id, target_user_id)
    {:reply, result, state}
  end

  def handle_call({:unmute_member, group_id, actor_user_id, target_user_id}, _from, state) do
    result = Relay.do_unmute_member(group_id, actor_user_id, target_user_id)
    {:reply, result, state}
  end

  def handle_call({:handle_relay, request, fun_config}, _from, state) do
    result = Relay.do_handle_relay(request, fun_config)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.monitors, fn {_key, v} -> v == ref end) do
      nil ->
        {:noreply, state}

      {{group_id, user_id}, _ref} ->
        Logger.info(
          "[RelayServer] channel process down, cleaning up membership, group_id: #{group_id}, user_id: #{user_id}, reason: #{inspect(reason)}"
        )

        Relay.do_leave_group(group_id, user_id)
        new_monitors = Map.delete(state.monitors, {group_id, user_id})
        {:noreply, %{state | monitors: new_monitors}}
    end
  end
end
