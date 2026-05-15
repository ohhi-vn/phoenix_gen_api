# Relay Messages

Group-based message relaying for PhoenixGenApi. A user sends a message to a group, and all members (including the sender) receive it through their Phoenix Channel.

## Overview

```
Client A                    Gateway (Phoenix Channel)           Client B
  │  WebSocket: relay_msg                                      │
  │  {group_id, message}                                       │
  │──────────────────────────►│                                 │
  │                            │  handle_in()                    │
  │                            │   └─ Executor.execute!(request) │
  │                            │      └─ Relay.handle_relay()    │
  │                            │         ├─ ETS: validate member │
  │                            │         ├─ Registry: dispatch    │
  │                            │         └─ send(pid, {:relay_message, response})
  │                            │                                 │
  │                            │  handle_info({:relay_message})  │
  │                            │   └─ push(socket, result)──────►│
  │◄───────────────────────────│                                 │
  │  {status: "relayed",       │                                 │
  │   recipients_count: 2}     │                                 │
```

## Group Types

### `:public`

- Anyone can join immediately as `:active`.
- All members can send and receive messages.
- No acceptance step.

```elixir
:ok = PhoenixGenApi.Relay.create_group("public_room", :public, "admin", admin_pid)
{:ok, :active} = PhoenixGenApi.Relay.join_group("public_room", "any_user", user_pid)
```

### `:private`

- New members join with `:pending` status.
- Any existing `:active` member can accept pending members.
- Only `:active` members can send and receive.

```elixir
:ok = PhoenixGenApi.Relay.create_group("private_room", :private, "admin", admin_pid)
{:ok, :pending} = PhoenixGenApi.Relay.join_group("private_room", "new_user", user_pid)

# Any active member accepts
:ok = PhoenixGenApi.Relay.accept_member("private_room", "admin", "new_user")
```

### `:strict_private`

- New members join with `:pending` status.
- Only `:admin` members can accept pending members.
- Admins can `:mute` and `:unmute` members.
- Muted members **can receive** but **cannot send** messages.

```elixir
:ok = PhoenixGenApi.Relay.create_group("strict_room", :strict_private, "admin", admin_pid)
{:ok, :pending} = PhoenixGenApi.Relay.join_group("strict_room", "new_user", user_pid)

# Only admin can accept
:ok = PhoenixGenApi.Relay.accept_member("strict_room", "admin", "new_user")

# Admin mutes a member
:ok = PhoenixGenApi.Relay.mute_member("strict_room", "admin", "new_user")

# Muted member can't send but can receive
# Admin unmutes
:ok = PhoenixGenApi.Relay.unmute_member("strict_room", "admin", "new_user")
```

### Permission Matrix

| Action | `:public` | `:private` | `:strict_private` |
|---|---|---|---|
| Join | → `:active` | → `:pending` | → `:pending` |
| Accept | N/A | Any `:active` | Only `:admin` |
| Send | Any `:active` | Any `:active` | `:active` (not muted) |
| Receive | `:active` + `:muted` | `:active` + `:muted` | `:active` + `:muted` |
| Mute | ❌ | ❌ | Only `:admin` |
| Unmute | ❌ | ❌ | Only `:admin` |

## Data Stores

### ETS Table (`:phoenix_gen_api_relay_groups`)

Stores group metadata:

```elixir
{group_id, group_type, members_map}

# members_map:
%{
  "user_1" => %{
    roles: MapSet.new([:admin]),
    status: :active,
    joined_at: ~U[2025-01-15 10:00:00Z]
  },
  "user_2" => %{
    roles: MapSet.new([:member]),
    status: :pending,
    joined_at: ~U[2025-01-15 10:05:00Z]
  }
}
```

### Registry (`PhoenixGenApi.RelayRegistry`)

With `:duplicate` keys, maps group members to their channel processes:

```elixir
# key: group_id
# value: {user_id, channel_pid}

Registry.register(PhoenixGenApi.RelayRegistry, "room_1", {"user_1", channel_pid_1})
Registry.register(PhoenixGenApi.RelayRegistry, "room_1", {"user_2", channel_pid_2})
```

## Configuration

### FunConfig for relay_msg

```elixir
alias PhoenixGenApi.Structs.FunConfig

config = %FunConfig{
  request_type: "relay_msg",
  service: "chat_service",
  nodes: :local,
  choose_node_mode: :random,
  timeout: 5_000,
  mfa: {PhoenixGenApi.Relay, :handle_relay, []},
  arg_types: %{
    "group_id" => :string,
    "message" => :string
  },
  arg_orders: ["group_id", "message"],
  response_type: :sync,
  check_permission: :any_authenticated
}

PhoenixGenApi.ConfigDb.add(config)
```

### Application Setup

The relay infrastructure is automatically added to the supervision tree:

```elixir
# In PhoenixGenApi.Application — automatically included:
children = [
  # ... existing children ...
  {Registry, keys: :duplicate, name: PhoenixGenApi.RelayRegistry}
]

# ETS table is created in start/2:
:ets.new(PhoenixGenApi.Relay.table(), [:set, :public, :named_table])
```

When `client_mode: true`, neither the Registry nor the ETS table is created.

## Client Protocol

### Sending a Message

WebSocket push to the channel event (default `"phoenix_gen_api"`):

```json
{
  "service": "chat_service",
  "request_type": "relay_msg",
  "request_id": "req_123",
  "args": {
    "group_id": "room_1",
    "message": "Hello everyone!"
  }
}
```

### Response to Sender

```json
{
  "request_id": "req_123",
  "success": true,
  "result": {
    "status": "relayed",
    "recipients_count": 3
  }
}
```

### Message Received by All Members

Each member's channel pushes the relay message:

```json
{
  "request_id": "req_123",
  "success": true,
  "result": {
    "group_id": "room_1",
    "from_user_id": "user_1",
    "message": "Hello everyone!",
    "timestamp": "2025-01-15T10:30:00Z"
  }
}
```

## Direct API

Manage groups programmatically outside of WebSocket requests:

```elixir
# Create a group
:ok = PhoenixGenApi.Relay.create_group("room_1", :public, "admin", admin_channel_pid)

# Join
{:ok, :active} = PhoenixGenApi.Relay.join_group("room_1", "user_2", user2_channel_pid)

# Leave
:ok = PhoenixGenApi.Relay.leave_group("room_1", "user_2")

# Accept a pending member
:ok = PhoenixGenApi.Relay.accept_member("room_1", "admin", "user_2")

# Mute / Unmute (strict_private only)
:ok = PhoenixGenApi.Relay.mute_member("room_1", "admin", "user_2")
:ok = PhoenixGenApi.Relay.unmute_member("room_1", "admin", "user_2")

# Inspect group
{:ok, info} = PhoenixGenApi.Relay.get_group_info("room_1")
# %{group_id: "room_1", group_type: :public, members: %{"admin" => %{...}, "user_2" => %{...}}}

# Delete a group
:ok = PhoenixGenApi.Relay.delete_group("room_1")
```

## Error Handling

| Condition | Error Response |
|---|---|
| Group not found | `"Group not found"` |
| Not a member | `"Not a member of this group"` |
| Pending membership | `"Pending membership: wait for acceptance"` |
| Muted member sending | `"You are muted and cannot send messages"` |
| Non-admin accepting (strict) | `{:error, :not_admin}` |
| Non-admin muting/unmuting | `{:error, :not_admin}` |
| Muting on non-strict group | `{:error, :not_strict_private}` |

## Complete Example: Chat Channel

```elixir
# lib/my_app_web/channels/chat_channel.ex
defmodule MyAppWeb.ChatChannel do
  use Phoenix.Channel
  use PhoenixGenApi, event: "chat"

  def join("chat:" <> group_id, _payload, socket) do
    # Auto-join the relay group on channel join
    case PhoenixGenApi.Relay.join_group(group_id, socket.assigns.user_id, self()) do
      {:ok, _status} -> {:ok, socket}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  def handle_info({:relay_message, response}, socket) do
    push(socket, "chat", response.result)
    {:noreply, socket}
  end
end
```

```elixir
# FunConfig for the relay
%FunConfig{
  request_type: "send_message",
  service: "chat_service",
  nodes: :local,
  mfa: {PhoenixGenApi.Relay, :handle_relay, []},
  arg_types: %{"group_id" => :string, "message" => :string},
  arg_orders: ["group_id", "message"],
  response_type: :sync,
  check_permission: :any_authenticated
}
```

```javascript
// Client: join a chat room
const channel = socket.channel("chat:room_1", {});
channel.join();

// Client: send a message to the room
channel.push("chat", {
  service: "chat_service",
  request_type: "send_message",
  request_id: "msg_" + Date.now(),
  args: {
    group_id: "room_1",
    message: "Hello everyone!"
  }
});

// Client: receive relayed messages
channel.on("chat", (payload) => {
  console.log(`${payload.result.from_user_id}: ${payload.result.message}`);
});
```

## Implementation Notes

- **Registry dispatch**: `send_to_group/3` uses `Registry.select/2` with a match spec to find all `{user_id, channel_pid}` entries for a group, then sends `{:relay_message, response}` to each pid.
- **Channel process**: Each user's channel process receives the `{:relay_message, response}` message via `handle_info`, which pushes the payload to the client through the WebSocket.
- **Self-inclusion**: The sender is included in the recipient list — they receive their own relayed message.
- **Pending exclusion**: Pending members are not in the recipient list — they cannot receive messages until accepted.
- **Muted members**: Muted members are in the recipient list (they receive) but cannot send.
