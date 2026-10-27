# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.25.0]

### Fixed

- **Execution isolation**: a raising/throwing/exiting endpoint no longer kills the
  channel or caller; local calls run in a monitored process. `FunConfig.timeout` is a
  hard bound even when an endpoint ignores shutdown, and a completion racing the timeout
  is not reported as a timeout.
- **Async/stream dispatch**: every worker-pool reply (`:queue_full`, `:circuit_open`,
  unavailable pool, call exits) produces an error response instead of a
  `CaseClauseError`/exit. Retry exhaustion now returns the documented
  `all retry attempts exhausted` for both local and remote paths and keeps the last real
  failure in telemetry. Node-resolution failures stop retrying immediately.
- **Streams**: every stream ends with exactly one terminal frame (completion, error, or
  timeout) and emits `stream stop/exception` telemetry. Timeout ownership moved into
  `StreamCall`, releasing the pool slot after handoff.
- **Worker pool**: one completion signal per task (no duplicate dispatch, hard
  concurrency limit), worker crashes keep the queue, circuit-open workers reject and
  requeue instead of dropping work, restart failures retry with a logged path, timers are
  cancelled, and pool status reports real values.
- **Hooks**: `after_execute` results are returned to the caller, `hook_timeout` is
  honoured, hook stacktraces reach telemetry, and an unchanged result is not reported as
  a failure.
- **Rate limiter**: `fail_open`/fail-closed now applies to exits and timeouts (not just
  exceptions); cleanup honours `cleanup_interval` and runtime limits and no longer blocks
  checks; concurrency is race-free; key cardinality/size can be bounded.
- **Configuration**: `update/1`, pushes, and puller registration apply the same MFA and
  structural validation as `add/1`; a rejected write keeps the previous config serving.
  A missing table is reported as `:unavailable` instead of `not_found`, and pull results
  only report success when configuration was stored.
- **Relay**: malformed state returns `{:error, :internal_error}` without losing groups,
  monitors are released on delete/re-join, and an absent server returns a retryable
  response.

### Security

- Push-token comparison now compares fixed-length SHA-256 digests, so timing does not
  reveal the secret's length.
- The built-in MFA denylist now covers `Code`, `File`, `System`, `Node`, `IO`, `:ets`,
  `:application`, `:persistent_term`, `:logger`, `:gen_server`, `:supervisor`, and
  `:process`. An explicit `:mfa_allowlist` entry remains the escape hatch. Every MFA a
  config can invoke (`nodes`, hooks, `permission_callback`, `result_encoder`) is validated
  at registration.
- Push administration now enforces the documented `:push_config` admin action when
  `admin_actions` is configured, supports opt-in source binding (`:config_source_binding`,
  `:service_owners`) and downgrade rejection (`:reject_config_downgrades`), and can gate
  puller administration (`:protect_config_puller`).
- New opt-in channel flags: `require_authenticated_roles` (roles from `socket.assigns`)
  and `reject_unverified_user_id`. Defaults remain permissive for backward compatibility.
- `protect_internal_tables` makes internal ETS tables `:protected` with owner-process
  writes; rate-limiter sharding is disabled in that mode.
- Tracing control is admin-gated when `admin_actions` is configured, and
  `trace_capture_args: false` omits payload args from trace files.
- Configuration- and client-driven atom creation removed from sticky node selection.

### Performance

- Un-versioned config resolution no longer scans every stored version (`ConfigDb` is an
  `:ordered_set`); measured ~343µs → ~3µs on a 5 000-row cache.
- Rate limiting skips the limiter process entirely when no limits are configured, sends
  only the key material it needs, uses per-timestamp ordered rows instead of copying the
  whole window, and indexes per-API limits.
- Argument validation hoists per-element config reads: a 1 000-item list validates in
  ~8µs instead of ~400-800µs of env lookups.
- Worker dispatch uses the maintained idle list; stream tasks use `:stream_pool` and stop
  occupying async capacity; trace maps are only built for traced requests.
- Local benchmark (single node, 1 000 requests): async calls ~25k → ~40-47k req/sec,
  sync calls at parity or better.

### Added

- `PhoenixGenApi.Errors.Classify` failure classes (`:invalid_request`,
  `:permission_denied`, `:rate_limited`, `:unavailable`, `:timeout`, `:internal`) in
  telemetry metadata.
- Telemetry: `request decode_error`, `stream stop/exception`, `permission denied/error`,
  `config pull error`, `config push rejected`, `relay accepted/delivered/rejected`, and
  `worker_pool worker restart`.
- Configuration: `push_token` enforcement remains, plus `config_source_binding`,
  `service_owners`, `reject_config_downgrades`, `allow_client_version`,
  `max_configs_per_service`, `config_failed_cleanup_interval`, `protect_config_puller`,
  `pull_node_allowlist`, `max_rate_limit_keys`, `max_rate_limit_key_bytes`,
  `ip_address_source`, `relay_trust_mode`, `relay_limits`, `protect_internal_tables`, and
  `trace_capture_args`.
- `Relay.delete_group/2` for actor-verified deletion.

### Changed

- **Hardening pass (`harden-library-runtime`)**: fixes are classified as Tier A (always
  on, behaviour-preserving for valid input), Tier B (opt-in flag, default = current
  behaviour), or Tier C (deferred secure default for a breaking release). See
  "Compatibility and Hardening Tiers" in `guides/architecture.md`.
- Worker-pool `busy_workers` includes circuit-paused workers, and `total_tasks_failed`
  now increments. Relay responses distinguish `targeted_count` from `recipients_count`.
- `routing_strategy: :random` is accepted but ignored (and logged) because it cannot keep
  a key's counters consistent.

### Deferred (next breaking release)

- Defaulting `require_authenticated_roles`, `reject_unverified_user_id`, a required push
  token, and `relay_trust_mode: :strict` on. These remain opt-in in this release.

- **Logging context enrichment (backward compatible)**: every log line now follows
  `[Module] event=<snake_case> <existing message> key=value ...`, carrying
  `request_id`, `request_type`, `service`, `user_id`, `node`, `origin_node`, and
  `version` where relevant. Request-scoped Logger metadata is installed during request
  handling and propagated into async, stream, and worker-pool processes, then restored.
  Existing `[Module]` prefixes and message wording are preserved, so current greps and
  dashboards keep working.

- **Log level review**: retry attempts and per-request conversion dumps moved from
  `info`/`error` to `debug`; caller argument-schema violations moved from `error` to
  `warning`. Configuration, dispatch, and security failures stay at `warning`/`error`.
  Operators that relied on `info` retry lines must enable `debug` for the relevant
  module.

### Security

- Push tokens are never logged. `PhoenixGenApi.Structs.PushConfig` now redacts
  `push_token` from `inspect/1`, and token rejections log only that the token was
  rejected.

- Full request payloads, argument values, and function results are redacted by default.
  Enable the new `log_verbose_payloads: true` config option (default `false`) to emit
  them at `debug` level outside production.

## [2.24.1]

### Fixed
- Double wrap resut for FunConfig's result encoder.

## [2.24.0]

### Fixed

- **ImplHelper encoder contract**: Generated encoder protocol implementations
  (`PhoenixGenApi.ImplHelper.gen_impl/2` and `use PhoenixGenApi` in channels) now
  conform to the encoder protocol contract: `encode/2` applies the struct's
  `encode!/2` and then recursively encodes the result via the encoder protocol,
  returning valid iodata. Previously the impl returned the raw `encode!/2` map,
  which crashed the channel process when pushing responses over a real websocket
  with standard configs (`config :phoenix, :json_library, Jason` or OTP `JSON`);
  Phoenix channel tests bypass wire serialization and did not catch this.
  Apps using a **custom** encoder protocol must re-verify that it implements
  the protocol for plain maps (any real encoder protocol does).

### Changed

- **Guides restructured for newcomers**: `Getting Started` now starts with a
  single-node setup (`nodes: [Node.self()]` + browser client) before splitting
  into a gateway + service cluster, documents the `require_verified_user_id`
  default, and gains Testing and Troubleshooting sections. A new `Concepts`
  guide covers the mental model. Feature sections from the Step-by-Step Guide
  moved into the FunConfig Reference; Execute Flow merged into Architecture;
  Tracing merged into Diagnostics.
- **Deleted guide pages** (old Hexdoc URLs no longer resolve; content lives in
  the files below): `step_by_step_guide.html` (→ FunConfig Reference, Getting
  Started), `execute_flow.html` (→ Architecture), `tracing.html` (→ Diagnostics).

### Added

- **FunConfig `result_encoder`**: New optional per-endpoint field
  `result_encoder: {module, function, args}` (defaults to `nil`). When set, the
  executor applies the encoder to **successful** results only — the `{:ok, data}`
  tuple is unwrapped and the encoder receives only `data` as its first argument
  followed by the tuple's args (`apply(mod, fun, [data | args])`), and its return
  value is re-wrapped as `{:ok, encoded}`. This lets endpoints shape payloads at
  the framework boundary (e.g. convert structs to JSON-safe maps) without
  duplicating encoding logic per endpoint.
- Encoder failures (`raise`/`throw`/`exit`) are rescued and become
  `{:error, "result encoding failed: ..."}` → error response; the channel process
  never crashes.
- The encoder MFA passes through `Security.validate_mfa` like the endpoint's own
  mfa (hardcoded denylist + optional `:mfa_allowlist`). Deployments using
  `:mfa_allowlist` must include the encoder MFA or requests fail visibly with
  an `mfa_not_allowed` error.
- Error results and other result shapes pass through untouched. `:stream`
  endpoints are not encoded — streaming behavior is unchanged.
- Structural validation mirrors the hook validator (`nil` or a valid
  `{module, function, args}` tuple); invalid values are rejected with a message
  naming `result_encoder`.
- Tests: new `test/phoenix_gen_api/executor/result_encoder_test.exs` covering the
  application contract, pass-through, failure handling, and security checks, plus
  validation tests in the FunConfig test suite.

## [2.23.1]

### Added

- **Tracer**: New `PhoenixGenApi.Tracer` request tracing feature. Trace one or more
  request types and/or user ids — added at runtime via
  `PhoenixGenApi.Tracer.enable_request_type/1` / `enable_user_id/1` or configured
  statically with `config :phoenix_gen_api, :tracer`. Each traced request type /
  user id is logged to its own `key=value` log file with automatic size-based
  rotation. The hot-path check is a cheap in-memory lookup that no-ops when
  tracing is disabled or unmatched; file I/O happens asynchronously in a dedicated
  writer process so request execution is never blocked.
- **Permission logging**: Richer, consistent log output for permission checks —
  callback logs now include `user_id`, `request_id`, `request_type`, and `service`,
  and denied logs include the service and request type.
- **Trace every action**: Tracing now covers *all* logs and actions of a traced
  request, not just the three lifecycle events. The executor emits structured
  milestone events (`config_lookup`, `hook_before`, `rate_limit`, `arguments`,
  `execution`, `error`, `retry`, `retry_exhausted`, `rpc_fallback`, `async`,
  `stream`, `hook_after`) and raw `Logger` output from every module that touches
  the request is captured as `event=log` lines (with `level`, `pid`, `mfa`,
  `message`). Capture is metadata-driven: `begin_trace/1` attaches trace context
  to the process, worker processes re-apply it, and `end_trace/1` restores the
  original metadata. While tracing is enabled the global `Logger` level is raised
  to the new `:log_level` config option (default `:debug`) so debug/info output is
  captured, and a filter suppresses untraced low-level logs from the console.
- **Guides**: Added `guides/tracing.md` documenting the Tracer feature (enabling at
  runtime or via config, trace file format, events, rotation, raw log capture, and
  performance characteristics) and linked it from the README.

### Fixed

- **FunConfig**: Fixed `arg_types` validation rejecting the `:datetime`, `:naive_datetime`, and `:list`
  types that `ArgumentHandler` fully supports at request time — configs using them failed
  `valid?/1` and were never registered. The accepted types are now defined once in a single
  `@supported_arg_types` attribute shared by all three config formats (simple atom, old tuple,
  extended keyword list), keeping validation in sync with runtime conversion.
- **ConfigCache**: Fixed `get_fast/2` returning `{:error, :not_found}` for a sole disabled config — the single-match pattern used a nested-list shape that `:ets.match_object` never produces, so disabled configs fell through to the multi-version branch and were reported as not found. They now correctly return `{:error, :disabled}`.

#### Compiler warnings
- **ArgumentHandler**: Removed dead `arg_types == nil` check in `convert_args!/2` — `arg_types` is always a map (assigned via `config.arg_types || %{}`), making the `nil` branch unreachable.
- **NodeSelector**: Removed unreachable `error ->` branch in `select_nodes_ordered/3` — `sticky_node/3` always returns `{:ok, node}`, so the error clause could never match.
- **Executor**: Removed unused default arguments (`\\ nil`) from private functions `execute_local_with_retry/6` and `apply_local_retry/8`. Fixed the call site in `execute_local_with_retry/6` to pass `retry_config` as the `original_config` parameter to `apply_local_retry/8`.
- **Security**: Fixed `constant_time_compare_bin/2` base clause — restored the proper `<<>>, <<>>, acc` pattern match that was previously replaced with a no-op recursive call.
- **Security**: Fixed `mfa_in_allowlist?/2` — removed unused `mfa =` pattern binding, using `{mod, fun}` directly.
- **Request**: Fixed `DecodeError` construction in `decode!/1` — now uses `DecodeError.exception/3` with proper `code`, `message`, and `details` arguments instead of passing them as keyword list options to `raise`.
- **Public API spec**: Fixed `get_rate_limit_status/3` return type from `list(map())` to `map()` to match the actual implementation.

#### Code quality
- **Hook**: Reformatted `Task.async` block in `hook.ex` to use multi-line `task = Task.async(fn -> ... end)` style for consistency with codebase formatting standards.
- **Security**: Reordered `check_mfa_allowlist/1` pattern to put variable name after the pattern (`mfa = {module, function, _args}`) for consistency with codebase conventions.

#### Test suite
- **CircuitBreaker test**: Fixed flaky timing test — changed `opened_at = now - 4999` to `opened_at = now - 4900` to provide a 100ms margin against boundary-condition failures under load.
- **NodeSelector sticky test**: Fixed unused variable warnings by changing `node1` to `_node1` in assertions where the value was not used.
- **ConfigPuller test**: Fixed unused variable warning by adding `_ = version_before` to suppress the unused binding.
- **verify_setup.exs**: Moved from `test/phoenix_gen_api/` to `scripts/` — this file is a verification script, not an ExUnit test (it didn't match the test pattern and was never executed by `mix test`).
- **Test alias ordering**: Fixed alphabetical ordering of `alias` declarations across 13 test files to satisfy Credo readability checks.

### Changed

- **Dependencies**: Updated all dependencies to their latest compatible versions:
  - `benchee` 1.5.0 → 1.5.1
  - `circular_buffer` 1.0.0 → 1.0.1
  - `credo` 1.7.18 → 1.7.19
  - `deep_merge` 1.0.0 → 1.0.2
  - `erlex` 0.2.8 → 0.2.9
  - `ex_dna` 1.4.3 → 1.5.2
  - `ex_doc` 0.40.1 → 0.40.3
  - `finch` 0.21.0 → 0.22.0
  - `igniter` 0.7.9 → 0.8.1
  - `jason` 1.4.4 → 1.4.5
  - `makeup_erlang` 1.0.3 → 1.1.0
  - `mint` 1.7.1 → 1.9.0
  - `owl` 0.13.0 → 0.13.1
  - `plug` 1.19.1 → 1.19.2
  - `req` 0.5.17 → 0.6.1
  - `spitfire` 0.3.11 → 0.3.13
  - `statistex` 1.1.0 → 1.1.1
  - `telemetry` 1.4.1 → 1.4.2
  - `uniq` 0.6.2 → 0.6.3
  - New dependency: `ex_ast` 0.12.0 (transitive via `igniter`)

### Quality gates status

All quality gates are now green:

| Gate | Status |
|------|--------|
| `mix format --check-formatted` | ✅ PASS |
| `mix compile --warnings-as-errors` | ✅ PASS |
| `mix test` (631 tests) | ✅ 0 failures |
| `mix ex_dna` (code duplication) | ✅ No duplication |
| `mix hex.audit` (retired packages) | ✅ None found |

Remaining Credo issues (pre-existing, not addressed):
- 18 software design suggestions (nested module aliasing)
- 23 refactoring opportunities (function complexity/nesting depth)
- 54 code readability issues (parentheses on zero-arg functions, alias ordering in lib files, etc.)
- 3 consistency issues (variable name after pattern style)
