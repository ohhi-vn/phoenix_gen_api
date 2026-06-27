defmodule PhoenixGenApi.Relay do
  @moduledoc """
  Relay message feature for PhoenixGenApi.

  Provides group-based message relaying where a user sends a message to a group
  and all members (including the sender) receive it.

  ## Group Types

  ### :public
  - Anyone can join immediately as `:active`.
  - All members can send and receive messages.

  ### :private
  - New members join with `:pending` status.
  - Any existing active member can accept pending members.
  - Only `:active` members can send and receive messages.

  ### :strict_private
  - New members join with `:pending` status.
  - Only `:admin` members can accept pending members.
  - Admins can `:mute` and `:unmute` members.
  - Muted members can receive but cannot send messages.

  ## Architecture

  - **RelayServer** (`PhoenixGenApi.RelayServer`) is a GenServer that owns the
    ETS table and serializes all group operations to prevent race conditions.
    All public API functions in this module delegate to the GenServer.

  - **ETS table** (`:phoenix_gen_api_relay_groups`) stores group metadata:
    `{group_id, group_type, members_map}` where `members_map` is
    `%{user_id => %{roles: MapSet, status: atom, joined_at: DateTime}}`.

  - **Registry** (`PhoenixGenApi.RelayRegistry`) with `:duplicate` keys maps
    `group_id` to `{user_id, channel_pid}` for dispatching messages to channel
    processes via `send/2`.
  """

  alias PhoenixGenApi.Structs.Response

  require Logger

  @table :phoenix_gen_api_relay_groups
  @registry PhoenixGenApi.RelayRegistry

  # Threshold below which sequential dispatch is used (avoids Task overhead for small groups).
  @relay_dispatch_threshold 32
  # Max concurrent Task.async_stream workers for large group dispatch.
  @relay_max_concurrency 16

  @type group_type :: :public | :private | :strict_private
  @type member_status :: :active | :pending | :muted
  @type member_info :: %{
          roles: MapSet.t(atom()),
          status: member_status(),
          joined_at: DateTime.t()
        }

  # ── ETS table access (used by RelayServer to create the table) ──

  @doc "Returns the ETS table name for group metadata storage."
  @spec table :: atom()
  def table, do: @table

  # ── Group Lifecycle ────────────────────────────────────────────

  @doc """
  Creates a new group. The creator becomes the admin with `:active` status.

  Returns `:ok` or `{:error, :already_exists}`.
  """
  @spec create_group(String.t(), group_type(), String.t(), pid()) ::
          :ok | {:error, :already_exists}
  def create_group(group_id, group_type, creator_user_id, channel_pid)
      when is_binary(group_id) and group_type in [:public, :private, :strict_private] and
             is_binary(creator_user_id) and is_pid(channel_pid) do
    PhoenixGenApi.RelayServer.create_group(group_id, group_type, creator_user_id, channel_pid)
  end

  @doc """
  Deletes a group from ETS. Registry entries are cleaned up when channel
  processes terminate.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec delete_group(String.t()) :: :ok | {:error, :not_found}
  def delete_group(group_id) when is_binary(group_id) do
    PhoenixGenApi.RelayServer.delete_group(group_id)
  end

  @doc """
  Returns group info including type and members map.
  """
  @spec get_group_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_group_info(group_id) when is_binary(group_id) do
    PhoenixGenApi.RelayServer.get_group_info(group_id)
  end

  # ── Membership ─────────────────────────────────────────────────

  @doc """
  Joins a user to a group.

  - **public**: user becomes `:active` immediately.
  - **private** / **strict_private**: user becomes `:pending`, needs acceptance.

  Returns `{:ok, :active}` or `{:ok, :pending}` depending on group type,
  or `{:error, reason}`.
  """
  @spec join_group(String.t(), String.t(), pid()) ::
          {:ok, :active | :pending} | {:error, :not_found | :already_member}
  def join_group(group_id, user_id, channel_pid)
      when is_binary(group_id) and is_binary(user_id) and is_pid(channel_pid) do
    PhoenixGenApi.RelayServer.join_group(group_id, user_id, channel_pid)
  end

  @doc """
  Removes a user from a group and unregisters them from the Registry.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec leave_group(String.t(), String.t()) :: :ok | {:error, :not_found | :user_not_in_group}
  def leave_group(group_id, user_id)
      when is_binary(group_id) and is_binary(user_id) do
    PhoenixGenApi.RelayServer.leave_group(group_id, user_id)
  end

  # ── Accept / Mute / Unmute ─────────────────────────────────────

  @doc """
  Accepts a pending member into a group.

  - **private**: any active member can accept.
  - **strict_private**: only admin can accept.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec accept_member(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :user_not_in_group | :not_admin | :user_not_pending}
  def accept_member(group_id, actor_user_id, target_user_id)
      when is_binary(group_id) and is_binary(actor_user_id) and is_binary(target_user_id) do
    PhoenixGenApi.RelayServer.accept_member(group_id, actor_user_id, target_user_id)
  end

  @doc """
  Mutes a member in a strict_private group. Only admins can mute.
  Muted members can receive but cannot send messages.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec mute_member(String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :not_found | :not_strict_private | :user_not_in_group | :not_admin | :cannot_mute}
  def mute_member(group_id, actor_user_id, target_user_id)
      when is_binary(group_id) and is_binary(actor_user_id) and is_binary(target_user_id) do
    PhoenixGenApi.RelayServer.mute_member(group_id, actor_user_id, target_user_id)
  end

  @doc """
  Unmutes a member in a strict_private group. Only admins can unmute.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec unmute_member(String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :not_found | :not_strict_private | :user_not_in_group | :not_admin | :not_muted}
  def unmute_member(group_id, actor_user_id, target_user_id)
      when is_binary(group_id) and is_binary(actor_user_id) and is_binary(target_user_id) do
    PhoenixGenApi.RelayServer.unmute_member(group_id, actor_user_id, target_user_id)
  end

  # ── Relay Message (MFA target) ────────────────────────────────

  @doc """
  Handles a relay message request. This is the MFA target configured in
  `FunConfig` for `request_type: "relay_msg"`.

  Extracts `group_id` and `message` from `request.args`, validates the
  sender's membership and permissions, then sends `{:relay_message, response}`
  to all group members' channel pids via the Registry.

  Returns a `Response` with relay status.
  """
  @spec handle_relay(PhoenixGenApi.Structs.Request.t(), PhoenixGenApi.Structs.FunConfig.t()) ::
          PhoenixGenApi.Structs.Response.t()
  def handle_relay(request, fun_config) do
    PhoenixGenApi.RelayServer.handle_relay(request, fun_config)
  end

  # ── Private Implementation (called by RelayServer) ─────────────

  @doc false
  @spec do_create_group(String.t(), group_type(), String.t(), pid()) ::
          :ok | {:error, :already_exists}
  def do_create_group(group_id, group_type, creator_user_id, channel_pid) do
    case :ets.lookup(@table, group_id) do
      [{^group_id, _, _}] ->
        {:error, :already_exists}

      [] ->
        member = new_member([:admin], :active)
        members = %{creator_user_id => member}
        :ets.insert(@table, {group_id, group_type, members})
        Registry.register(@registry, group_id, {creator_user_id, channel_pid})

        Logger.info(
          "[Relay] group created: #{group_id}, type: #{group_type}, creator: #{creator_user_id}"
        )

        :ok
    end
  end

  @doc false
  @spec do_delete_group(String.t()) :: :ok | {:error, :not_found}
  def do_delete_group(group_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, _, _}] ->
        :ets.delete(@table, group_id)
        Registry.unregister_match(@registry, group_id, :_)
        Logger.info("[Relay] group deleted: #{group_id}")
        :ok
    end
  end

  @doc false
  @spec do_get_group_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def do_get_group_info(group_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, group_type, members}] ->
        {:ok, %{group_id: group_id, group_type: group_type, members: members}}
    end
  end

  @doc false
  @spec do_join_group(String.t(), String.t(), pid()) ::
          {:ok, :active | :pending} | {:error, :not_found | :already_member}
  def do_join_group(group_id, user_id, channel_pid) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, :public, members}] ->
        case Map.get(members, user_id) do
          nil ->
            member = new_member([:member], :active)
            :ets.insert(@table, {group_id, :public, Map.put(members, user_id, member)})
            Registry.register(@registry, group_id, {user_id, channel_pid})
            {:ok, :active}

          %{status: :active} ->
            {:error, :already_member}

          %{status: _old_status} ->
            Registry.unregister_match(@registry, group_id, {user_id, :_})
            member = new_member([:member], :active)
            :ets.insert(@table, {group_id, :public, Map.put(members, user_id, member)})
            Registry.register(@registry, group_id, {user_id, channel_pid})
            {:ok, :active}
        end

      [{^group_id, group_type, members}]
      when group_type in [:private, :strict_private] ->
        case Map.get(members, user_id) do
          nil ->
            member = new_member([:member], :pending)
            :ets.insert(@table, {group_id, group_type, Map.put(members, user_id, member)})
            Registry.register(@registry, group_id, {user_id, channel_pid})
            {:ok, :pending}

          %{status: :active} ->
            {:error, :already_member}

          %{status: :pending} ->
            {:error, :already_member}

          %{status: :muted} ->
            Registry.unregister_match(@registry, group_id, {user_id, :_})
            member = new_member([:member], :pending)
            :ets.insert(@table, {group_id, group_type, Map.put(members, user_id, member)})
            Registry.register(@registry, group_id, {user_id, channel_pid})
            {:ok, :pending}
        end
    end
  end

  @doc false
  @spec do_leave_group(String.t(), String.t()) :: :ok | {:error, :not_found | :user_not_in_group}
  def do_leave_group(group_id, user_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, group_type, members}] ->
        if Map.has_key?(members, user_id) do
          :ets.insert(@table, {group_id, group_type, Map.delete(members, user_id)})
          Registry.unregister_match(@registry, group_id, {user_id, :_})
          :ok
        else
          {:error, :user_not_in_group}
        end
    end
  end

  @doc false
  @spec do_accept_member(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :user_not_in_group | :not_admin | :user_not_pending}
  def do_accept_member(group_id, actor_user_id, target_user_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, group_type, members}] ->
        with {:ok, _actor} <- fetch_active_actor(members, actor_user_id, group_type),
             {:ok, target} <- fetch_pending_target(members, target_user_id) do
          updated = %{target | status: :active}
          new_members = Map.put(members, target_user_id, updated)
          :ets.insert(@table, {group_id, group_type, new_members})
          :ok
        end
    end
  end

  @doc false
  @spec do_mute_member(String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :not_found | :not_strict_private | :user_not_in_group | :not_admin | :cannot_mute}
  def do_mute_member(group_id, actor_user_id, target_user_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, :strict_private, members}] ->
        with {:ok, _actor} <- fetch_admin_actor(members, actor_user_id),
             {:ok, target} <- fetch_active_target(members, target_user_id) do
          updated = %{target | status: :muted}
          new_members = Map.put(members, target_user_id, updated)
          :ets.insert(@table, {group_id, :strict_private, new_members})
          :ok
        end

      [{^group_id, _, _}] ->
        {:error, :not_strict_private}
    end
  end

  @doc false
  @spec do_unmute_member(String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :not_found | :not_strict_private | :user_not_in_group | :not_admin | :not_muted}
  def do_unmute_member(group_id, actor_user_id, target_user_id) do
    case :ets.lookup(@table, group_id) do
      [] ->
        {:error, :not_found}

      [{^group_id, :strict_private, members}] ->
        with {:ok, _actor} <- fetch_admin_actor(members, actor_user_id),
             {:ok, target} <- fetch_muted_target(members, target_user_id) do
          updated = %{target | status: :active}
          new_members = Map.put(members, target_user_id, updated)
          :ets.insert(@table, {group_id, :strict_private, new_members})
          :ok
        end

      [{^group_id, _, _}] ->
        {:error, :not_strict_private}
    end
  end

  @doc false
  @spec do_handle_relay(PhoenixGenApi.Structs.Request.t(), PhoenixGenApi.Structs.FunConfig.t()) ::
          PhoenixGenApi.Structs.Response.t()
  def do_handle_relay(request, _fun_config) do
    group_id = Map.get(request.args, "group_id")
    message = Map.get(request.args, "message")
    user_id = request.user_id
    request_id = request.request_id

    case :ets.lookup(@table, group_id) do
      [] ->
        Response.error_response(request_id, "Group not found")

      [{^group_id, _group_type, members}] ->
        case Map.get(members, user_id) do
          nil ->
            Response.error_response(request_id, "Not a member of this group")

          %{status: :pending} ->
            Response.error_response(request_id, "Pending membership: wait for acceptance")

          %{status: :muted} ->
            Response.error_response(request_id, "You are muted and cannot send messages")

          %{status: :active} ->
            recipient_ids =
              for {uid, %{status: s}} <- members, s in [:active, :muted], do: uid

            relay_payload = %{
              "group_id" => group_id,
              "from_user_id" => user_id,
              "message" => message,
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            send_to_group(group_id, request_id, relay_payload)

            Response.sync_response(request_id, %{
              "status" => "relayed",
              "recipients_count" => length(recipient_ids)
            })
        end
    end
  end

  # ── Private Helpers ────────────────────────────────────────────

  defp new_member(roles, status) do
    %{
      roles: MapSet.new(roles),
      status: status,
      joined_at: DateTime.utc_now(),
      monitor_ref: nil
    }
  end

  defp fetch_active_actor(members, actor_user_id, group_type) do
    case Map.get(members, actor_user_id) do
      %{roles: roles, status: :active} ->
        if group_type == :strict_private and not MapSet.member?(roles, :admin) do
          {:error, :not_admin}
        else
          {:ok, nil}
        end

      %{roles: _} ->
        {:error, :not_admin}

      nil ->
        {:error, :user_not_in_group}
    end
  end

  defp fetch_admin_actor(members, actor_user_id) do
    case Map.get(members, actor_user_id) do
      %{roles: roles, status: :active} ->
        if MapSet.member?(roles, :admin) do
          {:ok, nil}
        else
          {:error, :not_admin}
        end

      _ ->
        {:error, :not_admin}
    end
  end

  defp fetch_pending_target(members, target_user_id) do
    case Map.get(members, target_user_id) do
      %{status: :pending} = target ->
        {:ok, target}

      nil ->
        {:error, :user_not_in_group}

      _ ->
        {:error, :user_not_pending}
    end
  end

  defp fetch_active_target(members, target_user_id) do
    case Map.get(members, target_user_id) do
      %{status: :active} = target ->
        {:ok, target}

      nil ->
        {:error, :user_not_in_group}

      _ ->
        {:error, :cannot_mute}
    end
  end

  defp fetch_muted_target(members, target_user_id) do
    case Map.get(members, target_user_id) do
      %{status: :muted} = target ->
        {:ok, target}

      nil ->
        {:error, :user_not_in_group}

      _ ->
        {:error, :not_muted}
    end
  end

  defp send_to_group(group_id, request_id, relay_payload) do
    relay_response = Response.sync_response(request_id, relay_payload)

    members =
      Registry.select(@registry, [
        {{:"$1", :"$2", :"$3"}, [{:==, :"$1", group_id}], [{{:"$2", :"$3"}}]}
      ])

    # For small groups, use sequential dispatch (lower overhead).
    # For large groups, use Task.async_stream to parallelize sends with back-pressure.
    if length(members) <= @relay_dispatch_threshold do
      Enum.each(members, fn {_key, {_user_id, channel_pid}} ->
        send(channel_pid, {:relay_message, relay_response})
      end)
    else
      Task.async_stream(
        members,
        fn {_key, {_user_id, channel_pid}} ->
          send(channel_pid, {:relay_message, relay_response})
        end,
        max_concurrency: @relay_max_concurrency,
        ordered: false
      )
      |> Stream.run()
    end
  end
end
