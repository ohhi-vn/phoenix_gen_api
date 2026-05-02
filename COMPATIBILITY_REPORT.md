# PhoenixGenApi Compatibility Report

## Comparison: Old (8296995) vs Current (HEAD)

### Commit History
- **Old**: `8296995` - "improve security & performance"
- **Current**: `62f0e2f` - "update default config for worker pool, add benchmark script"

---

## ✅ Non-Breaking Changes (Additive Only)

### 1. Added `:sticky` Node Selection Strategy

**File**: `lib/phoenix_gen_api/structs/fun_config.ex`

```elixir
# Old type spec:
choose_node_mode: :random | :hash | {:hash, String.t()} | :round_robin,

# New type spec:
choose_node_mode: :random | :hash | {:hash, String.t()} | :round_robin | {:sticky, String.t()},
```

**Impact**: ✅ **NON-BREAKING** - Additive change. Existing code using `:random`, `:hash`, etc. continues to work.

---

### 2. Added Sticky Node Affinity Support

**File**: `lib/phoenix_gen_api/node_selector.ex`

Added new functions (all private `defp`):
- `sticky_node/3`
- `get_sticky_value/2`
- `build_sticky_key/3`
- `ensure_sticky_table/0`
- `sticky_valid?/1`
- `select_and_store_sticky/2`
- `cleanup_sticky_table/0` (now public `def`)

Modified existing private functions to handle `{:sticky, hash_key}`:
- `select_node/3`
- `select_nodes_ordered/3`

**Impact**: ✅ **NON-BREAKING** - All changes are internal/private. Public API unchanged.

---

### 3. Return Type Change (Internal Only)

**File**: `lib/phoenix_gen_api/node_selector.ex`

```elixir
# Old (private functions):
defp hash_node(request, nodes) do
  ...
  Enum.random(nodes)  # returned bare node
  Enum.at(nodes, hash_order)  # returned bare node
end

# New (private functions):
defp hash_node(request, nodes) do
  ...
    {:ok, Enum.random(nodes)}  # wrapped in {:ok, node}
    {:ok, Enum.at(nodes, hash_order)}  # wrapped in {:ok, node}
end
```

**Impact**: ✅ **NON-BREAKING** - These are `defp` (private) functions. External code cannot call them directly.

---

### 4. Added Sticky ETS Table

**File**: `lib/phoenix_gen_api/node_selector.ex`

```elixir
@sticky_table_name :phoenix_gen_api_sticky_nodes
@sticky_ttl_ms 3_600_000  # 1 hour TTL
```

**Impact**: ✅ **NON-BREAKING** - New ETS table for sticky mappings. Doesn't affect existing functionality.

---

### 5. Added Periodic Cleanup for Sticky Table

**File**: `lib/phoenix_gen_api/config_cache/config_puller.ex`

Added:
- `Process.send_after(self(), :cleanup_sticky, 3_600_000)` in `handle_continue(:load_initial_data, state)`
- `handle_info(:cleanup_sticky, _state)` callback

**Impact**: ✅ **NON-BREAKING** - New periodic cleanup. Doesn't affect existing APIs.

---

### 6. Made `cleanup_sticky_table` Public

**File**: `lib/phoenix_gen_api/node_selector.ex`

```elixir
# Old:
defp cleanup_sticky_table do
  ...
end

# New:
def cleanup_sticky_table do
  ...
end
```

**Impact**: ✅ **NON-BREAKING** - Made public so it can be called from `ConfigPuller`. Was previously dead code (defined but never called).

---

## 📊 Public API Compatibility Check

### `PhoenixGenApi` module
- ✅ No changes to public functions
- ✅ `execute!/1` still works the same
- ✅ `push_config/2` unchanged
- ✅ All telemetry functions unchanged

### `PhoenixGenApi.ConfigDb`
- ✅ `add/1`, `get/3`, `delete/3` unchanged
- ✅ Added `get_fast/2` (additive, doesn't break existing)

### `PhoenixGenApi.Executor`
- ✅ `execute!/1`, `execute_with_config!/2` unchanged
- ✅ Internal optimizations (Task.async skip for fast calls)

### `PhoenixGenApi.NodeSelector`
- ✅ `get_node/2`, `get_nodes/2` return types unchanged
- ✅ New `{:sticky, key}` mode is additive

### `PhoenixGenApi.RateLimiter`
- ✅ All public functions unchanged
- ✅ Internal optimization (timestamp handling)

### `PhoenixGenApi.WorkerPool`
- ✅ `execute_async/2`, `status/1` unchanged
- ✅ Internal optimization (idle worker lookup)

---

## 🎉 Conclusion

**✅ FULLY BACKWARD COMPATIBLE**

All changes between `8296995` and `HEAD` are:
1. **Additive** - New features added without removing old ones
2. **Internal** - Optimizations and new private functions
3. **Non-breaking** - Public API signatures unchanged

### What's New (Safe to Use)
- `:sticky` node selection strategy
- `cleanup_sticky_table/0` now public and called periodically
- Performance optimizations (no API changes)
- Benchmark script (`scripts/benchmark.exs`)

### Migration Notes
- **No migration needed** - Old code will work unchanged
- **Optional**: Use `{:sticky, key}` in `choose_node_mode` for sticky node affinity
- **Optional**: Use `PhoenixGenApi.NodeSelector.cleanup_sticky_table()` manually if needed

---

## 📝 Recommendations

1. **Keep using existing APIs** - They're all still supported
2. **Try `:sticky` mode** for stateful services that benefit from node affinity
3. **Run benchmarks** to see performance improvements:
   ```bash
   mix run scripts/benchmark.exs -- --mode local --concurrency 50 --requests 1000
   ```
