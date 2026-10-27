# Proposal

## Why

The library now has enough surface for production scale — remote config distribution,
cluster RPC, rate limiting, worker pools, streams, and relay groups — but hardening has
not kept pace with feature growth. Three classes of defect recur across the codebase:

- **Wasted work on the request path**: un-versioned config resolution scans the whole
  ETS table, the rate limiter always pays a `GenServer.call` (copying the full request)
  even with no limits configured, argument validation re-reads application config per
  element, and idle-worker selection rebuilds a 1 000-entry list per dispatch.
- **Failures that crash, hang, or vanish**: linked execution tasks kill the caller on a
  raising endpoint, `CaseClauseError` on `:circuit_open`, rate-limiter `fail_open` never
  catching `:exit`, streams that never signal completion, duplicate `worker_done`
  messages that bypass pool concurrency, and `:retry_exhausted` discarding the real
  reason while the docs promise a different message.
- **Trust boundaries that fail open**: `user_roles` is read from the client payload,
  the documented `:push_config` admin gate is never called, `ConfigDb.update/1` skips
  MFA validation, `nodes:`/hooks/`permission_callback` MFAs bypass the allowlist, and
  pushed service configs can schedule RPC against arbitrary nodes.

None of these require a redesign. They are a coherent hardening pass: measured
hot-path fixes, defence-in-depth at every trust boundary, and error paths that report
one honest outcome instead of crashing or lying.

## What Changes

**Request execution**
- Execute endpoint and timeout-guarded calls in unlinked tasks so an endpoint crash
  becomes an error response instead of a dead channel.
- Validate every MFA a `FunConfig` can invoke (`mfa`, `nodes`, hooks,
  `permission_callback`), not only the primary endpoint.
- Handle every documented worker-pool error reply (`:queue_full`,
  `:circuit_open`, process exits) and preserve the last real failure through retry
  exhaustion while keeping today's response text mapping.
- Stop building trace payloads, re-resolving permission nodes, and re-copying the
  request through pool hops when tracing is off or the value is already known.
- Close streams with an explicit terminal frame on timeout or abnormal termination.

**Worker pool**
- One completion signal per task; ignore `worker_done` for unknown or already-idle
  workers; mark circuit-open workers unavailable for the cooldown instead of silently
  discarding queued work.
- Survive a worker crash without discarding the queue; cancel task timers on
  completion; keep `status/1` fields truthful (pool-level failure counter, no
  resurrected pids).
- Dispatch from the maintained idle list, and route stream tasks to the stream pool
  that is already started.

**Rate limiting**
- Skip the limiter entirely when no limits are configured; send only the key material
  the limiter needs instead of the whole request.
- Replace the "copy the whole timestamp list per check" window accounting with a
  bounded, race-safe representation; keep configured cleanup intervals and cleanup
  out of the reply path.
- Catch `:exit` so documented fail-open/fail-closed policy actually applies, and gate
  runtime limiter administration consistently when admin actions are configured.
- Bound key cardinality and size, and make the documented `:ip_address` key either
  resolvable or rejected at configuration time instead of silently doing nothing.

**Config distribution**
- Enforce the documented `:push_config` admin action when admin actions are
  configured, and validate MFAs in every write path (including `update/1`).
- Validate push/pull origins: optional source binding, service ownership, monotonic
  versions, and pull-node targets; bound versioned growth and failed-config retention.
- Distinguish "not found" from "cache unavailable", surface partial pull failure, and
  stop reporting success for pulls that stored nothing.
- Sweep expired failed-config records and make failed-config recording safe when the
  subsystem is not started.

**Runtime security**
- Make push-token comparison fixed-length (digest-based) so it no longer leaks secret
  length.
- Extend the MFA denylist to high-risk Erlang/Elixir modules, with the existing
  allowlist as the escape hatch.
- Opt-in enforcement that `user_roles` comes from the socket, not the payload, and
  that an unverified payload `user_id` is rejected.
- Replace atom-creating paths driven by configuration with existing-atom lookups;
  optional protection for named ETS tables and config-driven admin surfaces.

**Relay**
- Validate relay actors and membership against the authenticated sender; reject remote
  PIDs for local group membership.
- Bound group size, message size, and fan-out; demonitor on group deletion and re-join;
  keep the relay server responsive and its state intact on unexpected input.
- Emit relay lifecycle telemetry and distinguish "members" from "delivered".

**Cross-cutting error and telemetry contract**
- Classify failures as client error, server error, timeout, or unavailable, and expose
  that classification in telemetry without changing the public response struct.
- Add the missing failure telemetry (config pull/push rejections, permission errors,
  relay, stream stop/exception, decode errors) and correct documented event metadata.

Every change is either behaviour-preserving for valid input, or gated by a new
configuration flag whose default reproduces today's behaviour. Secure-by-default flips
for the opt-in flags are explicitly deferred (see Impact).

## Capabilities

### New Capabilities

- `request-execution`: request handling contract — config resolution, local/remote
  dispatch, retries, timeouts, task isolation, streaming lifecycle, and the error
  response produced for each failure class.
- `worker-pool`: pool capacity, queueing, worker lifecycle, circuit-breaker behaviour,
  async/stream isolation, and the accuracy of pool status reporting.
- `rate-limiting`: rate-limit keying, window accounting and memory bounds, fail mode,
  runtime administration, and consistency guarantees under concurrency.
- `config-distribution`: accepting, validating, versioning, storing, and pulling remote
  configuration, including authentication, provenance, retention limits, and failure
  reporting.
- `runtime-security`: the security primitives — admin gate, token comparison, MFA
  allowlist/denylist coverage, atom safety, trusted identity, and exposure of internal
  tables and admin surfaces.
- `relay-messaging`: relay group creation, membership, authorization, message delivery,
  fan-out limits, and relay server resilience.

### Modified Capabilities

<!-- None. fun-result-encoder and impl-helper-encoder describe response encoding and
     helper-module generation; this change leaves both behaviours untouched (response
     encoding is deliberately out of scope, see Impact). -->

## Impact

- **Code**: `Executor`, `StreamCall`, `WorkerPool`/`Worker`/`WorkerPoolSupervisor`,
  `RateLimiter`, `ConfigDb`/`ConfigReceiver`/`ConfigPusher`/`ConfigPuller`/`ConfigFailed`,
  `Security`, `Permission`, `ArgumentHandler`, `NodeSelector`, `Relay`/`RelayServer`,
  `Request`/`Response`/`FunConfig`/`PushConfig`, `Telemetry`, plus the channel macro in
  `PhoenixGenApi`.
- **New configuration (all default to current behaviour)**: push/role/identity trust
  flags, `:protect_config_db`, `:protect_config_puller`, `:reject_config_downgrades`,
  `:max_configs_per_service`, rate-limiter key caps and `:ip_address` source, relay
  limits and trust mode, extended MFA validation switches. No existing key changes
  meaning and no default is flipped.
- **Compatibility**: public functions, return shapes, response text for existing failure
  classes, struct fields, and default configuration are preserved. WebSocket message
  shapes only gain terminal stream frames that clients already receive on normal
  completion.
- **Security**: configs that invoke newly denylisted modules now fail validation; an
  explicit `:mfa_allowlist` entry remains the escape hatch. Closing the
  `user_roles`/payload-`user_id` holes by default requires a future breaking release and
  is **not** part of this change.
- **Performance**: no public API change; measured per-request reductions in config
  lookup, limiter overhead, argument validation, and idle-worker dispatch.
- **Dependencies**: none added.
- **Out of scope**: log content, levels, metadata, and secret redaction in logs (owned by
  the in-flight `improve-log-context` change); response encoding changes; new transports
  or protocols.
