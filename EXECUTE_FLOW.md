# PhoenixGenApi — Complete Execute Flow (Line-by-Line)

## Entry Point: Channel `handle_in/3`

**File**: `lib/phoenix_gen_api.ex` lines 734–790

```
handle_in("phoenix_gen_api", payload, socket)
  │
  ├─ 1. Override user_id from socket.assigns (if configured)
  │     └─ Only if socket.assigns.user_id is a non-empty binary
  │
  ├─ 2. Decode payload → Request struct
  │     └─ Request.decode!(params) via Nestru
  │     └─ Validates user_roles (filters non-binary, empty strings)
  │
  ├─ 3. Execute (wrapped in try/rescue)
  │     │
  │     ├─ Executor.execute!(request)
  │     │
  │     └─ On success: push(socket, event, response)
  │     └─ On exception: log error, return generic error response
  │
  └─ 4. {:reply, reply_result, socket}
```

---

## Phase 1: `Executor.execute!(request)`

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 168–253

```
execute!(request)
  │
  ├─ 1. Record start_time (monotonic microsecond)
  │
  ├─ 2. Emit telemetry [:executor, :request, :start]
  │
  ├─ 3. try do
  │     │
  │     ├─ 4. Resolve version: request.version || "0.0.0"
  │     │
  │     ├─ 5. ConfigDb.get(service, request_type, version)
  │     │     │
  │     │     ├─ {:ok, fun_config}
  │     │     │     └─ execute_with_config!(request, fun_config)  ──→ Phase 2
  │     │     │
  │     │     ├─ {:error, :not_found}
  │     │     │     └─ Log warning
  │     │     │     └─ Return error_response("unsupported function: ... version ...")
  │     │     │
  │     │     └─ {:error, :disabled}
  │     │           └─ Log warning
  │     │           └─ Return error_response("disabled function: ... version ...")
  │     │
  │     ├─ 6. Calculate duration
  │     │
  │     ├─ 7. Extract {success, async} from result
  │     │     └─ %Response{success: s, async: a} → {s, a}
  │     │     └─ _ → {true, false}  (fallback for non-Response tuples)
  │     │
  │     ├─ 8. Emit telemetry [:executor, :request, :stop]
  │     │
  │     └─ 9. Return result
  │
  └─ rescue e
        ├─ Emit telemetry [:executor, :request, :exception]
        └─ reraise e
```

### ConfigDb.get/3 — Direct ETS read (no GenServer call)

**File**: `lib/phoenix_gen_api/config_cache/config_cache.ex` lines 267–285

```
get(service, request_type, version)
  │
  ├─ :ets.lookup_element(__MODULE__, {service, request_type, version}, 2)
  │     │
  │     ├─ config when is_map(config)
  │     │     ├─ config.disabled == true  → {:error, :disabled}
  │     │     └─ otherwise                → {:ok, config}
  │     │
  │     └─ _  → {:error, :not_found}
  │
  └─ rescue ArgumentError  → {:error, :not_found}
```

---

## Phase 2: `Executor.execute_with_config!(request, fun_config)`

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 255–275

```
execute_with_config!(request, fun_config)
  │
  ├─ 1. Log debug: request_id, response_type
  │
  └─ 2. Hooks.run_before(before_execute, request, fun_config)
        │
        ├─ {:ok, new_request, new_fun_config}
        │     └─ do_execute_with_config!(new_request, new_fun_config)  ──→ Phase 3
        │
        └─ {:error, reason}
              ├─ Log warning: request_id, reason
              ├─ Build error_response("hook rejected: ...")
              ├─ Hooks.run_after(after_execute, request, fun_config, response)
              └─ Return response   ←── (Fix #8: was previously discarded)
```

### Hooks.run_before/3

**File**: `lib/phoenix_gen_api/hooks/hook.ex`

```
run_before(nil, request, fun_config)
  └─ {:ok, request, fun_config}   (no-op)

run_before({mod, fun}, request, fun_config)
  └─ execute_hook(:before, mod, fun, [request, fun_config])
       │
       ├─ Telemetry :start
       ├─ apply(mod, fun, args) in try/rescue
       ├─ Telemetry :stop or :exception
       │
       ├─ Returns {:ok, {:ok, new_request, new_fun_config}} → proceed
       ├─ Returns {:ok, {:error, reason}} → abort
       ├─ Returns {:ok, _} → proceed with original request/fun_config
       └─ Returns {:error, reason} → abort

run_before({mod, fun, extra_args}, request, fun_config)
  └─ Same but args = [request, fun_config | extra_args]
```

---

## Phase 3: `Executor.do_execute_with_config!(request, fun_config)`

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 277–327

```
do_execute_with_config!(request, fun_config)
  │
  └─ RateLimiter.check_rate_limit(request)  ──→ Phase 3a
        │
        ├─ :ok
        │     └─ try do
        │           │
        │           ├─ Permission.check_permission!(request, fun_config)  ──→ Phase 3b
        │           │     │
        │           │     ├─ true (permission granted) → continues below
        │           │     │
        │           │     └─ raises PermissionDenied
        │           │           ├─ Build error_response("Permission denied")
        │           │           ├─ Hooks.run_after(after_execute, ...)
        │           │           └─ Return error_response   ←── (Fix #7: no longer reraises)
        │           │
        │           ├─ Dispatch by response_type:
        │           │     │
        │           │     ├─ :sync   → do_call(request, fun_config)         ──→ Phase 4
        │           │     ├─ :async  → async_call(request, fun_config)      ──→ Phase 5
        │           │     ├─ :none   → async_call(request, fun_config)      ──→ Phase 5
        │           │     ├─ :stream → stream_call(request, fun_config)     ──→ Phase 6
        │           │     │
        │           │     └─ other
        │           │           └─ Log error
        │           │           └─ error_response("unsupported response type: ...")
        │           │
        │           ├─ Hooks.run_after(after_execute, request, fun_config, result)
        │           └─ Return result
        │
        └─ error (rate limiter returned error)
              ├─ handle_rate_limit_error(error, request, fun_config)  ──→ Phase 3c
              ├─ Hooks.run_after(after_execute, request, fun_config, result)
              └─ Return result
```

### Phase 3a: `RateLimiter.check_rate_limit(request)`

**File**: `lib/phoenix_gen_api/rate_limiter/rate_limiter.ex` lines 357–409

```
check_rate_limit(request)
  │
  ├─ enabled?() == false → :ok (rate limiting disabled)
  │
  ├─ Select instance (consistent hashing by request_id)
  │
  ├─ GenServer.call(instance, {:check_rate_limit, request})
  │     │
  │     └─ check_request_limits(request, state)
  │           │
  │           ├─ check_global_limits(request, global_limits)
  │           │     └─ For each global limit:
  │           │           ├─ Extract key_value from request (user_id, device_id, etc.)
  │           │           ├─ check_and_record(:rate_limiter_global, key, limit)
  │           │           │     ├─ Within limit → :ok
  │           │           │     └─ Exceeded → {:error, :rate_limited, details}
  │           │           └─ Emit exceeded telemetry
  │           │
  │           └─ check_api_limits(request, api_limits)
  │                 └─ For each matching API limit:
  │                       ├─ build_api_key(key_value, {service, request_type})
  │                       ├─ check_and_record(:rate_limiter_api, key, limit)
  │                       └─ Same :ok / {:error, :rate_limited, details}
  │
  ├─ Emit check telemetry
  │
  └─ rescue e (rate limiter itself crashed)
        ├─ fail_open?() → Log error, return :ok (allow request)
        └─ otherwise    → {:error, :rate_limiter_error, %{message: ...}}
```

### Phase 3b: `Permission.check_permission!(request, fun_config)`

**File**: `lib/phoenix_gen_api/permission.ex` lines 425–441

```
check_permission!(request, fun_config)
  │
  └─ if not check_permission(request, fun_config) do
        ├─ Log warning: user_id, request_id, request_type, mode
        └─ raise PermissionDenied
     end
     └─ nil (permission granted, returns nil implicitly)
```

**`check_permission/2` dispatch order** (most specific first):

```
1. permission_callback: {mod, fun, args}  → execute_permission_callback(mod, fun, [request | args])
2. check_permission: false                → true (public endpoint)
3. check_permission: :any_authenticated   → true if user_id is non-empty binary
4. check_permission: {:arg, arg_name}     → compare request.args[arg_name] with user_id
5. check_permission: {:role, roles}       → check user_roles ∩ allowed_roles ≠ ∅
6. Invalid check_permission mode          → log error, false
7. Invalid permission_callback format     → log error, fallback to check_permission mode
```

### Phase 3c: `handle_rate_limit_error/3`

```
handle_rate_limit_error({:error, :rate_limited, details}, request, _)
  └─ error_response("Rate limit exceeded. Retry after N seconds.") + can_retry: true

handle_rate_limit_error({:error, :rate_limiter_error, details}, request, _)
  └─ Log error (fail-closed)
  └─ error_response("Rate limit service unavailable", can_retry: true)

handle_rate_limit_error({:error, :permission_denied}, request, _)
  └─ Log warning
  └─ error_response("Permission denied")

handle_rate_limit_error(error, request, _)  (catch-all)
  └─ Log error (fail-closed)
  └─ error_response("Rate limit service unavailable", can_retry: true)
```

---

## Phase 4: `do_call(request, fun_config)` — Sync Execution

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 396–411

```
do_call(request, fun_config)
  │
  ├─ 1. ArgumentHandler.convert_args!(fun_config, request)
  │     │
  │     ├─ validate_args!(config, request)
  │     │     ├─ check_extra_args!(args, arg_types, ...)  → raises ArgumentError if extra
  │     │     └─ validate_all_args!(arg_types, args, ...)
  │     │           └─ For each arg: validate_arg!(name, type, params, value, allow_nil, request)
  │     │                 ├─ nil + not allow_nil → raises ArgumentError
  │     │                 └─ arg_validation!(type, value, name, request)
  │     │                       ├─ validate_simple_type!  (boolean, string, num, uuid, etc.)
  │     │                       └─ validate_complex_type! (string with max_bytes, list with max_items, etc.)
  │     │
  │     └─ Convert args to final format
  │           ├─ No arg_types → []
  │           ├─ arg_orders: :map → [converted_map]
  │           ├─ Single arg → Map.values(converted_args)
  │           └─ Multiple args → ordered list by arg_orders
  │
  ├─ 2. Build final_args = predefined_args ++ converted_args ++ info_args
  │     │
  │     └─ info_args(request, fun_config)
  │           ├─ request_info: false → []
  │           └─ request_info: true  → [%{request_id, user_id, device_id, stream_pid?}]
  │
  ├─ 3. Normalize retry config
  │     └─ FunConfig.normalize_retry(retry)
  │           ├─ nil → nil
  │           ├─ n (integer) → {:all_nodes, n}
  │           ├─ {:same_node, n} → {:same_node, n}
  │           └─ {:all_nodes, n} → {:all_nodes, n}
  │
  ├─ 4. Execute
  │     │
  │     ├─ local_service?(fun_config)  → execute_local_with_retry(mod, fun, args, timeout, retry)
  │     │     │
  │     │     ├─ execute_local(mod, fun, args, timeout)
  │     │     │     ├─ function_exported?(mod, fun, arity) check
  │     │     │     ├─ Task.async → apply(mod, fun, args)
  │     │     │     ├─ Task.yield(task, timeout) || Task.shutdown(task)
  │     │     │     │     ├─ {:ok, result} → result
  │     │     │     │     ├─ nil → {:error, "local execution timed out"}
  │     │     │     │     └─ {:exit, reason} → {:error, "local execution failed"}
  │     │     │     └─ not exported → {:error, :function_not_found}
  │     │     │
  │     │     └─ apply_local_retry(result, mod, fun, args, timeout, retry_config)
  │     │           ├─ retryable_error? && has_retry_remaining?
  │     │           │     ├─ Calculate backoff
  │     │           │     ├─ Process.sleep(backoff_ms)
  │     │           │     ├─ Emit retry telemetry
  │     │           │     └─ Recurse with {mode, n-1}
  │     │           └─ otherwise → return result
  │     │
  │     └─ remote service  → execute_remote_with_retry(mod, fun, args, fun_config, request, retry)
  │           │
  │           ├─ NodeSelector.get_nodes(fun_config, request)
  │           │     └─ resolve_nodes(config) → select_node(nodes, mode, request)
  │           │           ├─ :random → Enum.random
  │           │           ├─ :hash → hash-based selection
  │           │           ├─ {:hash, key} → hash on specific arg
  │           │           ├─ :round_robin → atomic counter
  │           │           └─ {:sticky, key} → ETS sticky table lookup
  │           │
  │           ├─ execute_remote_with_fallback([node | rest], mod, fun, args, timeout, request_id, _)
  │           │     │
  │           │     ├─ :rpc.call(node, mod, fun, args, timeout)
  │           │     │     ├─ {:badrpc, :timeout} → log warning, try next node
  │           │     │     ├─ {:badrpc, {:EXIT, reason}} → log warning, try next node
  │           │     │     ├─ {:badrpc, reason} → log warning, try next node
  │           │     │     └─ result → return result (success, stops fallback)
  │           │     │
  │           │     └─ execute_remote_with_fallback([], ...) → return last_error || {:error, "no target nodes"}
  │           │
  │           └─ apply_remote_retry(state)
  │                 ├─ {:same_node, n} → retry on same nodes
  │                 ├─ {:all_nodes, n} → retry on ALL nodes (re-resolved)
  │                 └─ _ → return result (no retry or exhausted)
  │
  └─ 5. handle_call_result(result, request_id)
        │
        ├─ {:error, reason} → error_response(request_id, get_error_message(result))
        ├─ {:ok, result}   → sync_response(request_id, result)
        ├─ non-tuple result → sync_response(request_id, result) + warning log
        └─ other tuple      → error_response(request_id, "Unexpected execution result") + error log
```

### `sync_call/2` — Wrapper around `do_call`

```
sync_call(request, fun_config)
  │
  └─ try do
        do_call(request, fun_config)
      rescue e  → error_response(request_id, get_error_message(e))
      catch :exit, reason  → error_response(request_id, get_error_message(reason))
      catch :throw, reason → error_response(request_id, get_error_message(reason))
      catch kind, reason   → error_response(request_id, get_error_message(reason))
     end
```

---

## Phase 5: `async_call(request, fun_config)`

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 714–751

```
async_call(request, fun_config)
  │
  ├─ 1. Capture receiver = self()
  │
  ├─ 2. Build task fn:
  │     │
  │     └─ try do
  │           result = sync_call(request, fun_config)   ──→ Phase 4 (sync_call)
  │           if response_type != :none:
  │             send(receiver, {:async_call, result})
  │         catch kind, reason:
  │           Log error
  │           if Process.alive?(receiver):   ←── (Fix #9: guard added)
  │             send(receiver, {:async_call, error_response})
  │        end
  │
  ├─ 3. WorkerPool.execute_async(:async_pool, task)
  │     │
  │     ├─ :ok
  │     │     ├─ response_type != :none → async_response(request_id)
  │     │     └─ response_type == :none → {:ok, :no_response}
  │     │
  │     └─ {:error, :queue_full}
  │           └─ error_response("Service temporarily unavailable", can_retry: true)
  │
  └─ 4. Caller receives {:async_call, result} via handle_info later
```

---

## Phase 6: `stream_call(request, fun_config)`

**File**: `lib/phoenix_gen_api/executor/executor.ex` lines 753–829

```
stream_call(request, fun_config)
  │
  ├─ 1. Capture receiver = self(), request_id
  │
  ├─ 2. Build task fn:
  │     │
  │     └─ try do
  │           StreamCall.start_link(%{request, fun_config, receiver})
  │           │
  │           ├─ {:ok, pid}
  │           │     ├─ if Process.alive?(receiver):   ←── (Fix #9: guard added)
  │           │     │     send(receiver, {:stream_started, request_id, pid})
  │           │     ├─ Process.monitor(pid)
  │           │     └─ receive {:DOWN, ^ref, :process, ^pid, _} -> :ok
  │           │         after timeout → GenServer.stop(pid, :timeout)
  │           │
  │           └─ {:error, reason}
  │                 └─ if Process.alive?(receiver):   ←── (Fix #9: guard added)
  │                       send(receiver, {:stream_response, error_response(...)})
  │         catch kind, reason:
  │           Log error
  │           if Process.alive?(receiver):   ←── (Fix #9: guard added)
  │             send(receiver, {:stream_response, error_response(...)})
  │        end
  │
  ├─ 3. WorkerPool.execute_async(:async_pool, task)
  │     │
  │     ├─ :ok → stream_response(request_id, :init)   ←── (Fix #1: no blocking receive)
  │     │
  │     └─ {:error, :queue_full}
  │           └─ error_response("Service temporarily unavailable", can_retry: true)
  │
  └─ 4. Caller receives messages later via handle_info:
        ├─ {:stream_started, request_id, pid} → Process.put(stream_call_pid, pid)
        └─ {:stream_response, response} → push to client
```

### StreamCall GenServer lifecycle:

```
StreamCall.start_link(args)
  │
  ├─ init → {:ok, args, {:continue, :start_stream}}
  │
  ├─ handle_continue(:start_stream, state)
  │     ├─ Executor.sync_call(request, fun_config)   ──→ Phase 4
  │     ├─ error? → send(receiver, {:stream_response, error}) → stop
  │     └─ success → send(receiver, {:stream_response, stream_response(result)}) → continue
  │
  ├─ handle_info({:result, data}, state)
  │     └─ send(receiver, {:stream_response, stream_response(result, true)})
  │
  ├─ handle_info({:last_result, data}, state)
  │     └─ send(receiver, {:stream_response, stream_response(result, false)}) → stop
  │
  ├─ handle_info({:error, error}, state)
  │     └─ send(receiver, {:stream_response, error_response(...)}) → stop
  │
  ├─ handle_info(:complete, state)
  │     └─ send(receiver, {:stream_response, stream_end_response(request_id)}) → stop
  │
  └─ handle_cast(:stop, state)  → send completion → stop
```

---

## Return to Channel: `handle_info` clauses

**File**: `lib/phoenix_gen_api.ex` lines 794–831

```
handle_info({:push, result}, socket)
  └─ push(socket, event, result)

handle_info({:stream_started, request_id, pid}, socket)   ←── (Fix #1: new clause)
  └─ Process.put({:phoenix_gen_api, :stream_call_pid, request_id}, pid)

handle_info({:stream_response, result}, socket)
  └─ push(socket, event, result)

handle_info({:async_call, result}, socket)
  └─ push(socket, event, result)

handle_info({:relay_message, result}, socket)
  └─ push(socket, event, result)
```

---

## Complete Flow Diagram

```
Client WebSocket
  │
  │  handle_in("phoenix_gen_api", payload, socket)
  ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. Decode payload → Request struct                             │
│ 2. Executor.execute!(request)                                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. ConfigDb.get(service, type, version) — direct ETS read      │
│    ├─ {:ok, fun_config} → continue                             │
│    ├─ {:error, :not_found} → error response                   │
│    └─ {:error, :disabled} → error response                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Hooks.run_before(before_execute, request, fun_config)       │
│    ├─ {:ok, req, cfg} → continue                               │
│    └─ {:error, reason} → after_execute hook + error response  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. RateLimiter.check_rate_limit(request)                       │
│    ├─ :ok → continue                                           │
│    ├─ {:error, :rate_limited, _} → error + can_retry          │
│    ├─ {:error, :rate_limiter_error, _} → error (fail-closed)  │
│    └─ catch-all → error (fail-closed)                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Permission.check_permission!(request, fun_config)           │
│    ├─ true → continue                                          │
│    └─ false → after_execute hook + error response (no reraise) │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. Dispatch by response_type                                   │
│    ├─ :sync   → do_call → sync_call wrapper → handle_call_result│
│    │           ├─ Local: Task.async → apply(mod, fun, args)    │
│    │           └─ Remote: :rpc.call with node fallback + retry │
│    ├─ :async  → WorkerPool → send({:async_call, result})      │
│    ├─ :none   → WorkerPool → fire-and-forget                  │
│    ├─ :stream → WorkerPool → StreamCall GenServer             │
│    └─ other   → error response                                │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 8. Hooks.run_after(after_execute, request, fun_config, result) │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ 9. Telemetry :stop event                                       │
│ 10. Return Response struct to channel                          │
│ 11. Channel pushes Response to client via WebSocket            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Error Handling Summary

| Error Source | Handling | Response |
|---|---|---|
| Config not found | `execute!` returns error | `"unsupported function: X version Y"` |
| Config disabled | `execute!` returns error | `"disabled function: X version Y"` |
| Before hook rejects | `execute_with_config!` returns error | `"hook rejected: reason"` |
| Rate limit exceeded | `handle_rate_limited` | `"Rate limit exceeded. Retry after Ns"` + `can_retry: true` |
| Rate limiter broken | `handle_rate_limit_error` (fail-closed) | `"Rate limit service unavailable"` + `can_retry: true` |
| Permission denied | `do_execute_with_config!` returns error (no reraise) | `"Permission denied"` |
| Arg validation fails | `ArgumentHandler` raises `ArgumentError` | Caught by `sync_call` rescue → `"Internal Server Error"` |
| Local execution timeout | `Task.yield` returns nil | `{:error, "local execution timed out"}` |
| Local MFA not found | `function_exported?` returns false | `{:error, :function_not_found}` |
| Remote RPC fails | Fallback to next node | Last error or `"no target nodes available"` |
| All retries exhausted | `apply_*_retry` returns last result | Error tuple propagated |
| Worker pool full | `execute_async` returns `{:error, :queue_full}` | `"Service temporarily unavailable"` + `can_retry: true` |
| Stream start fails | Task sends error to receiver | `"Failed to start stream"` |
| Unexpected exception | `execute!` rescue → telemetry + reraise | Caught by channel's try/rescue → generic error |
