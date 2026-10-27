defmodule PhoenixGenApi.Relay.HardeningTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Relay
  alias PhoenixGenApi.RelayServer
  alias PhoenixGenApi.Structs.{Request, Response}

  setup do
    original = %{
      trust: Application.get_env(:phoenix_gen_api, :relay_trust_mode),
      limits: Application.get_env(:phoenix_gen_api, :relay_limits)
    }

    group = "hard_group_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Relay.delete_group(group)

      restore(:relay_trust_mode, original.trust)
      restore(:relay_limits, original.limits)
    end)

    {:ok, group: group}
  end

  defp restore(key, nil), do: Application.delete_env(:phoenix_gen_api, key)
  defp restore(key, value), do: Application.put_env(:phoenix_gen_api, key, value)

  defp relay_request(group, message, user_id \\ "admin_user") do
    %Request{
      request_id: "relay_hard_#{System.unique_integer([:positive])}",
      request_type: "relay_msg",
      service: "relay_service",
      user_id: user_id,
      args: %{"group_id" => group, "message" => message}
    }
  end

  test "strict mode requires an actor to delete a group and verifies admin", %{group: group} do
    Application.put_env(:phoenix_gen_api, :relay_trust_mode, :strict)

    assert :ok = Relay.create_group(group, :public, "admin_user", self())
    assert {:ok, :active} = Relay.join_group(group, "member_user", self())
    # A non-admin actor cannot delete the group.
    assert {:error, :user_not_in_group} = Relay.delete_group(group, "stranger")
    assert {:error, :not_admin} = Relay.delete_group(group, "member_user")
    # The bare form refuses to act without an actor in strict mode.
    assert {:error, :actor_required} = Relay.delete_group(group)
    assert :ok = Relay.delete_group(group, "admin_user")
  end

  test "group size, message size, and recipient limits are enforced", %{group: group} do
    Application.put_env(:phoenix_gen_api, :relay_limits, %{
      max_group_size: 1,
      max_message_bytes: 5,
      max_recipients: 1
    })

    assert :ok = Relay.create_group(group, :public, "admin_user", self())
    assert {:error, :group_full} = Relay.join_group(group, "other_user", self())

    Application.put_env(:phoenix_gen_api, :relay_limits, %{max_message_bytes: 5})

    assert %Response{success: false, error: "Message too large"} =
             Relay.handle_relay(relay_request(group, "this-is-too-long"), nil)

    assert %Response{success: true} = Relay.handle_relay(relay_request(group, "ok"), nil)
  end

  test "malformed group state returns an error without killing the server or losing groups", %{
    group: group
  } do
    assert :ok = Relay.create_group(group, :public, "admin_user", self())
    :ets.insert(Relay.table(), {"hard_bad_group", :not_a_group_type, %{}})

    assert {:error, :internal_error} = Relay.join_group("hard_bad_group", "u1", self())
    assert Process.alive?(Process.whereis(RelayServer))
    assert {:ok, _info} = Relay.get_group_info(group)

    :ets.delete(Relay.table(), "hard_bad_group")
  end

  test "group deletion releases member monitors", %{group: group} do
    before = RelayServer.status().monitored_memberships

    assert :ok = Relay.create_group(group, :public, "admin_user", self())
    assert {:ok, :active} = Relay.join_group(group, "member_user", self())

    assert RelayServer.status().monitored_memberships == before + 1

    assert :ok = Relay.delete_group(group)
    assert RelayServer.status().monitored_memberships == before
  end

  test "relay lifecycle telemetry reports targeted and delivered counts", %{group: group} do
    parent = self()

    :telemetry.attach_many(
      "relay-hardening",
      [
        [:phoenix_gen_api, :relay, :accepted],
        [:phoenix_gen_api, :relay, :delivered],
        [:phoenix_gen_api, :relay, :rejected]
      ],
      fn event, _measurements, metadata, _config ->
        send(parent, {:relay_event, event, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach("relay-hardening") end)

    assert :ok = Relay.create_group(group, :public, "admin_user", self())
    assert {:ok, :active} = Relay.join_group(group, "member_user", self())
    assert {:ok, :active} = Relay.join_group(group, "other_user", self())

    assert %Response{success: true, result: result} =
             Relay.handle_relay(relay_request(group, "hello"), nil)

    assert result["targeted_count"] == result["recipients_count"]
    assert_receive {:relay_event, [:phoenix_gen_api, :relay, :accepted], %{targeted: 3}}
    assert_receive {:relay_event, [:phoenix_gen_api, :relay, :delivered], %{delivered: 3}}
  end

  test "relay is reported unavailable when the server is not running", %{group: group} do
    sup = PhoenixGenApi.Supervisor

    :ok = Supervisor.terminate_child(sup, RelayServer)

    assert %Response{success: false, error: "Relay unavailable", can_retry: true} =
             Relay.handle_relay(relay_request(group, "hi"), nil)

    {:ok, _pid} = Supervisor.restart_child(sup, RelayServer)
  end
end
