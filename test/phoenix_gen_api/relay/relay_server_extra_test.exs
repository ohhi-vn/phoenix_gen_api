defmodule PhoenixGenApi.RelayServerExtraTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Relay
  alias PhoenixGenApi.RelayServer

  @moduletag :capture_log

  setup do
    case start_supervised(RelayServer) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ets.delete_all_objects(:phoenix_gen_api_relay_groups)

    :ok
  end

  defp spawn_channel do
    spawn(fn ->
      receive do
        :stop -> :ok
        _ -> :noreply
      end
    end)
  end

  describe "status/0" do
    test "reports no groups when table is empty" do
      status = RelayServer.status()

      assert status.status == :ok
      assert status.group_count == 0
      assert status.groups == []
      assert is_integer(status.monitored_memberships)
    end

    test "reports group summaries with active counts" do
      pid_c = spawn_channel()
      pid_u = spawn_channel()
      :ok = Relay.create_group("st_grp", :public, "creator", pid_c)
      {:ok, :active} = Relay.join_group("st_grp", "user_1", pid_u)

      status = RelayServer.status()

      assert status.group_count == 1
      assert status.monitored_memberships >= 1

      [summary] = status.groups
      assert summary.group_id == "st_grp"
      assert summary.group_type == :public
      assert summary.member_count == 2
      assert summary.active_count == 2
    end

    test "reports active_count excluding pending members" do
      pid_c = spawn_channel()
      pid_p = spawn_channel()
      :ok = Relay.create_group("st_priv", :private, "creator", pid_c)
      {:ok, :pending} = Relay.join_group("st_priv", "pending_1", pid_p)

      status = RelayServer.status()

      assert status.group_count == 1
      [summary] = status.groups
      assert summary.member_count == 2
      assert summary.active_count == 1
    end
  end

  describe "leave_group/2 for a creator without a monitor entry" do
    test "succeeds and handles the nil monitor pop branch" do
      pid_c = spawn_channel()
      :ok = Relay.create_group("leave_creator", :public, "creator", pid_c)

      assert :ok = Relay.leave_group("leave_creator", "creator")

      {:ok, info} = Relay.get_group_info("leave_creator")
      assert not Map.has_key?(info.members, "creator")
    end
  end

  describe "handle_info DOWN with unknown ref" do
    test "ignores DOWN messages for untracked monitors" do
      send(RelayServer, {:DOWN, make_ref(), :process, self(), :normal})
      Process.sleep(50)
      assert Process.whereis(RelayServer) != nil
    end
  end

  describe "process monitoring cleanup via channel death" do
    test "removes monitored membership when channel dies" do
      pid_c = spawn_channel()
      pid_u = spawn_channel()
      :ok = Relay.create_group("mon_clean", :public, "creator", pid_c)
      {:ok, :active} = Relay.join_group("mon_clean", "user_1", pid_u)

      status = RelayServer.status()
      assert is_integer(status.monitored_memberships)

      Process.exit(pid_u, :kill)
      Process.sleep(100)

      {:ok, info} = Relay.get_group_info("mon_clean")
      assert not Map.has_key?(info.members, "user_1")
    end
  end
end