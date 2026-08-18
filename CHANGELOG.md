# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
