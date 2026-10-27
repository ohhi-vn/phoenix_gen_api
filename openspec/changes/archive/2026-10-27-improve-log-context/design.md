# Design

## Context

See `proposal.md` for motivation. The audit found 226 log statements across 28 modules
with no shared context contract:

- Request identity (`request_id`) is present in some executor, permission, and argument
  lines, but `service`, `request_type`, and `user_id` are inconsistent.
- Remote/RPC lines name the target `node` but omit the request identity and service;
  config lines name the service but omit the pushing/source node.
- `ConfigReceiver` logs classic validation failures with neither `service` nor the
  pushing node, and never says which request types were in the rejected document.
- Process-crossing work (async tasks, stream processes, worker pool tasks) only forwards
  the tracer metadata, not a general request context.
- `ConfigReceiver.validate_push_token/1` logs the raw token; channel debug lines and the
  argument handler log full payloads/arguments eagerly.
- Context strings are eagerly interpolated inside `Logger.*` calls, so `inspect/1` cost
  is paid even when the level is disabled.

Constraints:

- The library must not depend on a specific Logger formatter or backend.
- Existing `[Module]` prefixes and message phrases are used by operators and by the
  tracer's log capture, so they should remain present.
- Request handling runs in caller processes (channel, direct `execute!` callers), in
  spawned stream processes, and in worker-pool tasks; GenServer-owned logs (rate
  limiter instances, config receiver/puller) do not inherit the caller's metadata.
- Tracing temporarily rewrites Logger metadata (`PhoenixGenApi.Tracer`), so context
  installation must nest and restore correctly.

## Goals / Non-Goals

**Goals:**

- One documented context vocabulary, applied consistently, that makes a single line
  enough to locate the affected request, service, and node.
- Request context automatically available to all downstream logs in the same process and
  in async/stream/worker processes.
- No secrets or bulk user data in logs by default.
- Level choices that let operators suppress routine chatter without hiding faults.
- Zero public API or telemetry changes.

**Non-Goals:**

- Replacing the Logger backend, adding log shipping/rotation, or emitting JSON logs.
- Changing trace-file format or trace event names (richer raw log lines flow into traces
  automatically).
- Adding per-request sampling, rate-limited logging, or a new observability
  configuration surface beyond the verbose-payload switch.
- Guaranteeing log output as a machine contract beyond the documented key vocabulary
  and `[Module] event=` prefix.

## Decisions

### 1. Inline context is authoritative; Logger metadata is additive

Every line carries its context inline as `key=value`. Request-scoped Logger metadata is
installed as well, for formatters that render `$metadata` and for structured backends.

- Rationale: the default Elixir formatter ignores metadata; metadata-only would not fix
  the reported line. Message-only would deny structured consumers.
- Alternative rejected: JSON/ECS-only logging — invasive, formatter-dependent, and not
  the library's responsibility.
- Formatting rules:
  - Prefix: `[ModuleName] event=<snake_case> <existing message>` — the event token is
    added directly after the prefix, before the existing phrase.
  - Values render with `inspect/1` (so strings are quoted, atoms are `:atom`), matching
    the existing style.
  - Unknown-but-relevant values render as `unknown`; keys are never silently dropped.
  - One separator style: `key=value` pairs separated by a single space, with the
    human-readable sentence immediately after `event=`.

### 2. New `PhoenixGenApi.LogContext` helper owns the vocabulary

A small module provides:

- the canonical key list and `event/2` helpers for building lines;
- `request_context/2` (request, optional fun config) returning a map with
  `request_id`, `request_type`, `service`, `user_id`, `node`, `version`;
- `put/1` returning the previous keyword metadata, and `with_context/2` wrapping a
  function in `try/after` that restores with `Logger.reset_metadata/1`;
- `value/1` for `nil`-safe rendering, and `sensitive/1` / `payload/1` for redaction and
  verbose gating;
- `verbose_payloads?/0` reading `config :phoenix_gen_api, :log_verbose_payloads`
  (default `false`).

Rationale: one place to change keys/format, and one place to review redaction.
Alternative rejected: editing 226 call sites with ad-hoc string concatenation — drift is
guaranteed.

### 3. Install context at three layers, restore in `after`

- **Channel entry** (`PhoenixGenApi.__using__/handle_in` and `ChannelHelpers`): install
  a coarse context from the raw payload (`request_id`, `request_type`, `service`,
  `user_id` when present) plus `module` and the current `node` before decoding, so
  decode failures are traceable.
- **Executor** (`execute!/1`): install the authoritative request context saved from the
  decoded `Request`, nested outside `Tracer.begin_trace/1`; restore after the response
  and trace teardown. This also covers direct callers that bypass channels.
- **Config receiver**: in the push `handle_call`, derive the pushing node with
  `node(elem(from, 0))` and install a context (`service`, `config_version`,
  `origin_node`) for the duration of `do_push`, so every accept/skip/reject line inherits
  it.

Config puller/pusher and GenServers that own their logs do not inherit caller metadata;
they carry the needed identifiers in their own call payloads (pull task state already
holds `service` and `node`; the pusher knows `service`, `version`, `server_node`).

Alternative rejected: installing metadata globally in every GenServer — leaks across
unrelated calls and is hard to restore safely.

### 4. Propagate by copying metadata into spawned work, then restore

Async jobs, stream jobs, and worker-pool tasks already copy `Logger.metadata()` for
tracing. Extend that pattern: capture `Logger.metadata()` before spawning, apply it at the
start of the task, and restore the task process's previous metadata in `after`. Worker
processes are long-lived and reused, so a task without restoration would leak the prior
request's identity into the next one.

### 5. Node semantics

- Remote execution / node selection: the target node(s) of the attempt, plus the request
  identity. Fallback lines state `failed_node` and the fallback outcome.
- Received push: the pushing node (`node(pid)`), not the receiving gateway.
- Pull: the source node of the RPC attempt; on final failure, all attempted nodes or
  their count.
- Purely local events: the current node, emitted only when useful (startup, config
  mutations), not on every line.

### 6. Redaction and verbose payload gating

- Never log `push_token`; the rejection line records `token_rejected=true` plus service
  and origin node. Add `@derive {Inspect, except: [:push_token]}` to `PushConfig` so
  incidental `inspect/1` calls cannot leak it.
- Gate full payload/args/result dumps behind `log_verbose_payloads: true`, emitted at
  `debug`. Without it, log request identity plus `payload_size`/field names.
- Keep existing non-secret config values (services, request types, versions, MFAs)
  visible; they are operational metadata.

### 7. Level policy

- `error`: rejected config (invalid/unsafe), dispatch failure, exhausted retries,
  circuit-breaker open, node selection failure.
- `warning`: client input rejection, auth/permission denial, rate-limit exceeded, token
  rejection, partial config acceptance, fallback attempts.
- `info`: business/config lifecycle events (push accepted, batch inserted, version
  changed, worker pool started).
- `debug`: per-request steps, argument conversion dumps, retry attempts, cleanup counts.

Notable moves: executor retry `info` → `debug`; argument-schema violations `error` →
`warning` (server is healthy, caller input is not); argument conversion dumps stay
`debug` and become lazy (`Logger.debug(fn -> ... end)`) so `inspect/1` is not paid when
disabled. ConfigPusher/Puller accept/batch events remain `info`.

### 8. Audit table (module → enrichment)

| Module | Missing today | Added |
| --- | --- | --- |
| `ConfigReceiver` | service, version, origin node, request types | push context in every line; token redaction; request-type list/count on validation failure |
| `ConfigPuller` / `ConfigPusher` | service/version on some RPC failures | service + version + node on every attempt/outcome; attempt counts on final failure |
| `ConfigDb` / `ConfigFailed` | request_type on generic failures | service + request_type + version; source node already in `ConfigFailed` |
| `Executor` / `StreamCall` | service/request_type/node together | request context on all lines; failed node + fallback outcome; MFA on dispatch failures |
| `ArgumentHandler` | request identity in deep validators | request context threaded to all raises; lazy debug dumps |
| `Worker` / `WorkerPool` | request identity at pool boundary | executor-level rejection lines carry context; pool lines stay health-focused with pool + node |
| `RateLimiter` | request identity on exceeded/fail-open | context passed in the check payload and included inline |
| `Permission` / `Hooks` / `NodeSelector` / `Relay` | node or request identity on some paths | consistent request context and node names |
| Channel macro / `ChannelHelpers` | module + request context on results | coarse payload context, `event=`, payload-size instead of payload |
| `Security` / startup modules | actor/node on allowlist and startup lines | current node and actor/module where known |

## Risks / Trade-offs

- **Log volume grows** → levels are reviewed alongside fields, retry/cleanup lines move
  to `debug`, and payload dumps are opt-in. Revisit if hot-path volume regresses.
- **Eager `inspect/1` cost** → convert hot-path debug lines to the lazy `fn ->` form and
  build context once per request rather than per line.
- **Metadata collision with host app keys** → install only documented generic keys,
  restore the exact previous metadata in `after`, and document the keys.
- **Metadata leakage between reused worker tasks** → capture/restore per task, with an
  explicit test for consecutive requests on one worker.
- **Tracer interaction** → request context is installed before `begin_trace/1`; the
  tracer restores to the context-bearing snapshot, and the outer wrapper then restores
  the process default.
- **Log-parser compatibility** → `[Module]` prefix and existing phrase retained; the new
  `event=` token and fields are additive.
- **Longer lines** → accepted; the alternative is untraceable incidents. Keep MFAs and
  request-type lists bounded (count + first N) when a push contains many entries.
- **Test brittleness** → assert on key/value fragments and metadata, not whole-line
  equality.

## Migration Plan

1. Add `PhoenixGenApi.LogContext` and the `log_verbose_payloads` config key (default
   `false`).
2. Instrument the three entry layers (channel, executor, config receiver) and the
   async/stream/worker propagation.
3. Convert modules in descending operational impact: config receiver/puller/pusher,
   executor/stream, argument handler, worker pool/rate limiter, then permission, hooks,
   node selector, relay, security, startup.
4. Update guides with the key vocabulary and a formatter snippet; add a CHANGELOG entry.
5. Add tests for context presence, propagation, restoration, and redaction.

Rollback: revert the release; no persisted data, schema, or API changes. Operators who
relied on `info` retry lines will see them at `debug`, which is called out in the
CHANGELOG and configurable through standard Logger level controls.

## Open Questions

- Whether to expose a runtime toggle for verbose payload logging (e.g. a public
  setter) in addition to application config. Deferrable; the config key is sufficient
  for the initial release and adding a setter later is backward compatible.
