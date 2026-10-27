# Design

## Context

See `proposal.md` for motivation. Three facts shape the approach:

- The library is already wired for hardening — `PhoenixGenApi.Security` exists, a
  circuit breaker exists, payload caps exist, and ETS tables use
  `read_concurrency`/`write_concurrency`. The gaps are coverage (controls not applied on
  every path), correctness (a few controls do not do what their docs claim), and
  cost (work that is repeated or paid when the feature is off).
- Behaviour is spread across long modules (`Executor` ~1 470 lines, `ArgumentHandler`
  ~1 260, `RateLimiter` ~ 1 220) with several parallel entry points into the same state:
  `ConfigDb.add/update/batch_add`, `ConfigReceiver.push`, `ConfigPuller.add`,
  `RelayServer` calls, and direct `GenServer.call` to limiter/pool instances. Every
  control therefore has to be placed deliberately, not at one convenient call site.
- The change must be strictly backward compatible: no public API, struct,
  default-config, or response-shape change. That rules out flipping secure defaults in
  this change even where the current default is unsafe.

## Goals / Non-Goals

**Goals:**

- Remove per-request work that is proportional to unrelated state or repeated per element,
  with before/after evidence from `scripts/benchmark.exs` and focused micro-benchmarks.
- Ensure every accepted task, request, and stream produces exactly one outcome, and that
  the outcome is visible in telemetry.
- Apply each security control on every path that can reach the protected operation, and
  use deny-by-default where the operator has opted into a control.
- Keep every fix either behaviour-identical for valid input or behind a new flag whose
  default reproduces current behaviour.

**Non-Goals:**

- Flipping defaults for the new opt-in security flags (deferred to a breaking release).
- Log message content, levels, metadata, and log redaction (`improve-log-context`).
- Response encoding changes (`fun-result-encoder`), helper generation
  (`impl-helper-encoder`), new transports, or new dependencies.
- Replacing ETS-based config/limiter state with an external store.

## Decisions

### D1. Compatibility tiers decide how each fix ships

Each audit finding is assigned one tier before implementation:

| Tier | Meaning | Ships as |
| --- | --- | --- |
| A | Behaviour is preserved for valid input; only crashes, leaks, silent no-ops, or wasted work change | Always on |
| B | Observable behaviour could change for a documented, valid usage | New flag, default = today's behaviour |
| C | Closing the hole by default requires a breaking change | Documented follow-up; flag provided in Tier B |

Alternatives considered: ship everything always-on (rejected — violates the
compatibility constraint for roles/identity/version rules); ship only Tier A (rejected —
leaves the highest-severity trust-boundary gaps unaddressed for operators willing to opt
in).

Tier A examples: unlinked execution tasks, `catch :exit` in the limiter, `update/1` MFA
validation, extended denylist, `:ordered_set` config table, timer cancellation,
`to_existing_atom`, duplicate-completion guards.

Tier B examples: push source binding, downgrade rejection, local-only relay membership,
socket-derived roles, unverified-`user_id` rejection, protected ETS tables, relay limits,
trace argument capture.

Tier C examples: defaulting socket-derived roles on, defaulting `:require_push_token` on,
defaulting relay strict mode on.

### D2. Failure classification is internal metadata, not a struct change

Add a small internal module that maps an outcome to `:invalid_request | :permission_denied
| :rate_limited | :unavailable | :timeout | :internal`, plus the retry/attempt context.
It is attached to telemetry metadata and used to choose log levels; the `%Response{}`
struct, its fields, and existing message strings stay as they are (with the single
exception of retry exhaustion, which starts matching the text already promised in the
`Executor` docs).

Rationale: adding a field to `Response` would ripple through JSON encoding and every
client. Telemetry is where operators already look. Alternative considered: an
`error_code` field on `Response` — deferred because it is a public struct change.

### D3. Execution isolation uses `async_nolink`, with a supervised and an unsupervised form

`Task.Supervisor.async_nolink/2` when a task supervisor is running; `spawn_monitor` plus a
receive loop when it is not (client mode starts no pool). Both preserve the existing
`{:ok, _} | nil | {:exit, reason}` branch shapes in `execute_local/4` and
`execute_with_timeout!/2`, and both cancel/forcibly kill the task at the deadline.

Alternatives considered: `Task.async` plus `trap_exit` in the caller (rejected — changes
the caller's failure semantics and requires every caller to opt in); `Task.start_link`
under the pool supervisor (rejected — couples endpoint failures to pool capacity).

### D4. Config resolution switches the ETS table type, not the call sites

`ConfigDb` becomes an `:ordered_set` (same key tuple). Single-version lookups stay a
direct `lookup_element`, while `get_fast/2`'s partially-bound match is restricted to the
key prefix range instead of a full-table scan. Measured on a 5 000-row table: ~343 µs →
~2.9 µs per un-versioned lookup.

Alternatives considered: a secondary `{service, request_type} => config` index (better
constant factor, more write paths to update and a consistency risk on delete/disable);
switching `Executor` to "always resolve latest version first" (adds a second read per
request). Chosen approach has one line of schema impact and no write-path changes.

### D5. Limiter fast path uses a published snapshot; accounting uses per-timestamp rows

Three changes, ordered by risk:

1. Publish effective limits (count, global, per-API index) in `:persistent_term` from
   `init/1` and every mutation handler. `check_rate_limit/1` returns `:ok` immediately when
   no limits apply, and otherwise sends only `{user_id, device_id, service, request_type,
   args}`. The gating key material is included only when a limit uses it.
2. Replace `{key, [timestamps]}` with one `:ordered_set` row per timestamp keyed
   `{key, timestamp, unique}`; count with `:ets.select_count` over the key prefix and
   delete expired rows with `:ets.select_delete`. This removes the full-list copy and the
   per-check `Enum.reject`/`length` while keeping the sliding window exact.
3. Route a key to its instance by `phash2(key)` regardless of routing strategy, so checks
   for one key are serialized and no update is lost. `:random` remains accepted and is
   documented as deprecated because it cannot be made race-free without per-key locks.

Cleanup becomes a single shard-owned sweep run off the reply path, using
`state.cleanup_interval` and `state.global_limits`/`state.api_limits`.

Alternatives considered: bucketed counters with `:ets.update_counter` (fastest, but
changes `retry_after_ms` granularity); keeping the list and adding an `oldest_ts` fast path
(removes in-heap work but keeps two full-list copies per check). Chosen: exact windows,
bounded per-key state, no semantic drift.

### D6. One completion signal per worker task

The task's `after` block stops notifying the pool; the worker's monitor `:DOWN` is the
single completion source, and the `:task_exception` flag prevents double failure
accounting. The pool ignores completion for pids it does not know about and for pids
already marked idle. Idle dispatch pops the maintained idle list head instead of
rebuilding a `MapSet` list.

The pool traps exits and treats `{:EXIT, pid, reason}` like `{:DOWN, ...}` so a worker
crash no longer restarts the pool and discards its queue. A circuit-open worker replies
with a distinct rejection message, and the pool withholds it for the cooldown.

Stream work is dispatched to the already-started `:stream_pool`, and the stream-pool
worker is released after `StreamCall` ownership is handed to the awaiting process rather
than being held for the stream's lifetime.

Alternatives considered: keeping the `after` send and filtering duplicates in the pool
(rejected — leaves two code paths that can disagree); trapping exits only in tests
(rejected — the production failure remains).

### D7. Security validation is centralized per configuration object

`FunConfig`/`ServiceConfig`/`PushConfig` gain a single validation path that checks every
invocable MFA (`mfa`, `nodes`, hooks, `permission_callback`, `result_encoder`, pull
targets) and every structural rule. `ConfigDb.add/update/batch_add`,
`ConfigReceiver.push`, and `ConfigPuller.add` all call it, so a new write path cannot
silently skip a rule.

The denylist is extended to the Elixir wrappers of the same dangerous surfaces
(`Code`, `File`, `System`, `Node`, `IO`, `Kernel`, `Process`) and the high-risk Erlang
modules (`:ets`, `:application`, `:persistent_term`, `:logger`, `:gen_server`,
`:supervisor`, `:process`). The existing allowlist stays the explicit escape hatch;
allowlist matching remains exact (module or module/function, no prefixes).

Alternatives considered: allowlist-only mode as the default (rejected — breaks existing
deployments that never configured an allowlist); validating only at request time (rejected
— config would be accepted, then fail per request).

### D8. Trust-boundary flags are explicit and documented as transitional

New flags, all defaulting to current behaviour:

| Flag | Default | Effect when enabled |
| --- | --- | --- |
| `:require_authenticated_roles` | `false` | `user_roles` comes from socket assigns; payload roles ignored |
| `:reject_unverified_user_id` | `false` | Missing verified `user_id` removes the payload `user_id` |
| `:reject_config_downgrades` | `false` | Older versions rejected unless forced |
| `:config_source_binding` | `nil` | Push origin must be among the pushed `nodes` |
| `:service_owners` | `nil` | Pushes for a service must come from its owner |
| `:max_configs_per_service` | `nil` | Versioned config cap per service/request type |
| `:protect_internal_tables` | `false` | Named ETS tables are `:protected`; writes go through owners |
| `:protect_config_puller` | `false` | Puller registration and forced pulls are admin-gated |
| `:max_rate_limit_keys` | `nil` | Key cardinality cap with `:overflow` bucket fallback |
| `:max_rate_limit_key_bytes` | `nil` | Long keys hashed before storage |
| `:ip_address_source` | `nil` | Where `:ip_address` key material comes from |
| `:relay_trust_mode` | `:legacy` | `:strict` enables actor checks and local-only membership |
| `:relay_limits` | `nil` | Group size, message bytes, recipient caps |
| `:trace_capture_args` | `true` | `false` omits argument values from trace records |

Rationale: operators can harden a running deployment without a code change, and nobody
gets a surprise behaviour change on upgrade. The docs and CHANGELOG call out the
recommended production set.

### D9. Telemetry is extended additively and documented from one list

New events: `[:phoenix_gen_api, :request, :decode_error]`, `[:phoenix_gen_api, :stream,
:stop | :exception]`, `[:phoenix_gen_api, :permission, :denied | :error]`,
`[:phoenix_gen_api, :config, :pull, :error]`, `[:phoenix_gen_api, :config, :push,
:rejected]`, `[:phoenix_gen_api, :relay, :accepted | :delivered | :rejected]`,
`[:phoenix_gen_api, :worker_pool, :worker, :restart]`. Existing event names, measurements,
and metadata keys are unchanged; failure events add `failure_class` and `reason`.

Rationale: `attach_all/3` should observe every documented event, and operators should not
need to parse logs for failure reasons. Alternative: route everything through one generic
event (rejected — unusable filtering, breaks existing dashboards).

### D10. Receiver, cache, and relay servers get explicit failure boundaries

`ConfigReceiver`, `ConfigDb`'s mutation handler, `ConfigFailed`, and `RelayServer` wrap
their delegated work so an unexpected term becomes an error tuple plus telemetry instead
of a supervision restart. `ConfigFailed` becomes a real owner process with a periodic
sweep and lazily created table. Relay keeps mutations in its owner process but returns a
recipient snapshot so fan-out happens in the caller; relay monitors gain a `ref => member`
index.

Alternatives considered: leaving restarts as the recovery mechanism (rejected — ETS tables
owned by the crashed process are lost, which silently drops all config/relay state).

## Risks / Trade-offs

- [Extended denylist rejects a previously accepted, legitimate endpoint] → The allowlist
  is the documented escape hatch; CHANGELOG lists the added modules and the migration
  snippet. Only already-dangerous modules are affected.
- [`:ordered_set` lookup is O(log n) instead of O(1) for single-version reads] → Measured
  negligible against network/execution cost; the un-versioned path improves by two orders
  of magnitude. Guarded by a benchmark task with an acceptance threshold.
- [Per-timestamp limiter rows multiply row count by the window size] → State remains
  bounded by `max_requests` per key, cleanup deletes expired rows, and row count is
  observable in diagnostics; the alternative was copying the whole window per check.
- [Publishing limiter snapshots via `:persistent_term` penalizes writes] → Mutations are
  rare and operator-driven; the snapshot is replaced only on config changes.
- [Routing keys by hash makes `:random` a deprecation] → Documented; correctness requires
  it. Deployments that explicitly chose `:random` should see a startup warning, not a
  silent change.
- [Terminal stream frames may surface to clients that previously saw a hung stream] →
  That is the intended fix; frames use the existing `stream_response` message shape.
- [Retry-exhaustion message changes for clients] → It now matches the documented text and
  carries the same `can_retry: false`; listed in CHANGELOG.
- [Opt-in flags leave the default posture unsafe] → Documented explicitly in a "hardening
  checklist" and flagged as the next breaking change; the proposal names this trade-off.
- [Large diff across long modules risks regressions] → Land in the task order below, one
  subsystem per commit, each with focused tests; keep `mix test` and a smoke benchmark
  green per step.

## Migration Plan

1. Ship Tier A fixes first (no configuration required), then Tier B flags with docs.
2. Add the new flags to `config/config.exs` documentation comments and the configuration
   guide, with a recommended production set but unchanged defaults.
3. Update CHANGELOG: fixed crashes/leaks, perf numbers, denylist additions, new telemetry,
   new flags, and the deferred default flips.
4. Rollback: Tier A changes are individually revertible; every Tier B behaviour is turned
   off by removing its flag. No data migration and no ETS table renaming, so a downgrade
   to the previous release starts cleanly (old code ignores new flags).
5. Verify with the existing suite plus new tests for each scenario group; run
   `scripts/benchmark.exs` before/after and record the deltas in the change notes.

## Open Questions

None blocking. Whether to flip any Tier C default is a product decision for the next
breaking release and does not change this design.
