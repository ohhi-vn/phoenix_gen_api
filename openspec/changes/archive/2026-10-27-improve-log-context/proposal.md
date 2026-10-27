# Proposal

## Why

Operators cannot trace a failing request or config push from the logs alone. A typical
line such as:

```
[ConfigReceiver] PushConfig validation failed: errors=["nodes must be a non-empty list of atoms or strings"]
```

names neither the offending service, the request types it belongs to, nor the node that
pushed it. The same gap exists across the executor, worker pool, rate limiter, and
config puller/pusher: `request_id` is sometimes present, `service` / `request_type` /
target `node` are usually absent, and each module formats context differently. When an
incident spans a gateway and several service nodes, correlating a client request with a
push or RPC failure requires guesswork. The logging audit also found a leaked push token
and full payload/argument dumps at debug level, so widening detail must go together with
redaction.

## What Changes

- Introduce one canonical, documented set of log context keys and an `event=` field for
  every library log line, keeping the existing `[Module]` prefix and existing wording
  where possible so current greps and dashboards keep working.
- Attach request-scoped `Logger` metadata (`request_id`, `request_type`, `service`,
  `user_id`, `node`) once at the request entry points, and propagate it into async,
  stream, and worker-pool processes so every downstream line inherits it.
- Enrich config push/receive/pull lines with `service`, `config_version` / `version`,
  `request_type` lists or counts, and the relevant `node` (pushing node, pull source,
  RPC target).
- Enrich executor/RPC, worker-pool, rate-limiter, permission, hook, and relay lines with
  the missing request context and the resolved target node.
- Make inline context self-sufficient: a line must remain traceable when the consumer's
  formatter does not render Logger metadata, and must not rely on metadata alone.
- Redact secrets and bulk payloads: never log push tokens, and gate full payload /
  argument / result dumps behind a dedicated opt-in debug switch.
- Review levels: per-request retry/cleanup chatter moves to `debug`; genuine
  configuration and dispatch failures stay at `warning`/`error`.
- Document the context key contract and a recommended Logger formatter snippet in the
  guides so the metadata is visible without extra parsing.

## Capabilities

### New Capabilities

- `log-context`: the contract for context fields, metadata propagation, redaction, and
  level selection in every PhoenixGenApi log line.

### Modified Capabilities

<!-- No existing spec covers logging; fun-result-encoder and impl-helper-encoder only
     define result-encoding behavior. -->

## Impact

- **Code**: 226 log call sites across 28 modules — chiefly `Executor`, `StreamCall`,
  `ConfigReceiver`, `ConfigPusher`, `ConfigPuller`, `ConfigDb`, `ConfigFailed`,
  `ArgumentHandler`, `Worker` / `WorkerPool`, `RateLimiter`, `Permission`, `Hooks`,
  `NodeSelector`, `Relay` / `RelayServer`, `Security`, and the `__using__` channel
  macro plus `ChannelHelpers`.
- **New module**: a small `PhoenixGenApi.LogContext` helper for key formatting,
  metadata installation/restoration, and redaction; no new runtime dependencies.
- **Behavior**: log line content and levels change; Logger metadata keys are added to
  the caller's process during request handling and restored afterwards. Public APIs,
  return values, and telemetry events are unchanged.
- **Security**: push tokens stop being logged; payload/args/result dumps require an
  explicit opt-in.
- **Docs/tests**: guides gain a logging-context section; new tests assert context
  presence, metadata propagation into worker/stream processes, and redaction.
