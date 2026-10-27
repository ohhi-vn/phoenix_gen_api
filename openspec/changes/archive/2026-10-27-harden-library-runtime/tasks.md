# Tasks

## 1. Baseline and shared foundations

- [x] 1.1 Record the pre-change baseline: run `mix test` and `mix run scripts/benchmark.exs`, and save the output under `/private/var/folders/76/xt0kl9zj2ks6wsl1q13513h40000gn/T/opencode/harden-baseline/` so later tasks can compare. Verify the files exist and the suite is green.
- [x] 1.2 Add the internal failure classifier module (`PhoenixGenApi.Errors.Classify`) mapping `{outcome, reason}` to `:invalid_request | :permission_denied | :rate_limited | :unavailable | :timeout | :internal`, and unit-test each mapping in `test/phoenix_gen_api/errors/classify_test.exs`. Verify with `mix test test/phoenix_gen_api/errors/classify_test.exs`.
- [x] 1.3 Register the new failure telemetry events (`stream` stop/exception, `permission` denied/error, `config` pull error and push rejection, `relay` accepted/delivered/rejected, `worker_pool` worker restart, `request` decode error) in `Telemetry.list_events/0` with docs, without changing existing events. Verify with `mix test test/phoenix_gen_api/telemetry_test.exs` and confirm `attach_all/3` receives each new event.
- [x] 1.4 Add a compatibility-tier comment/checklist to `AGENTS.md`-adjacent contributor docs (or `guides/architecture.md`) stating the Tier A/B/C rule from `design.md` D1 so later reviewers can classify fixes. Verify the section is present and referenced from the CHANGELOG draft.

## 2. Request execution

- [x] 2.1 Replace linked `Task.async` execution in `Executor.execute_local/4` and `execute_with_timeout!/2` with a supervised `async_nolink` path plus an unsupervised `spawn_monitor` fallback, preserving existing return branches. Verify with new tests in `test/phoenix_gen_api/executor/isolation_test.exs` that a raising and an exiting endpoint leave the caller alive.
- [x] 2.2 Make shutdown hard-bounded: forcibly kill on deadline, return exactly one outcome when completion races the timeout, and remove the "timed out although it finished" case. Verify with a test that a deadline-ignoring endpoint returns the timeout outcome within the bounded margin.
- [x] 2.3 Handle every worker-pool reply shape for async and stream dispatch (`:queue_full`, `:circuit_open`, unavailable pool, `GenServer.call` exit) as an error response, and emit the classified failure event. Verify with tests covering each reply and a test that runs async dispatch with no pool started.
- [x] 2.4 Preserve the last real failure through retry exhaustion in both local and remote paths, stop retrying when node resolution fails, and return the documented exhaustion message. Verify with `test/phoenix_gen_api/executor/retry_test.exs` assertions on message, telemetry reason, and attempt count.
- [x] 2.5 Honour `after_execute` hook results and `hook_timeout`, keep stacktraces in hook telemetry, and stop reporting an unchanged-result hook as a failure. Verify with `test/phoenix_gen_api/hooks_extra_test.exs` plus an executor test asserting the modified response reaches the caller.
- [x] 2.6 Stop building trace payloads and MFA strings when tracing is off or the request is not traced; guard with the existing enabled flag and trace context instead of always building. Verify with a benchmark comparing a no-trace call before/after and a tracer test that no line is built for untraced requests.
- [x] 2.7 Hoist `Application.get_env` reads out of argument element loops and pass resolved limits into validation. Verify with `mix test test/phoenix_gen_api/argument_handler_test.exs test/phoenix_gen_api/argument_handler_edge_test.exs` and a benchmark showing flat cost for a 1 000-item list.
- [x] 2.8 Reject container-type mismatches with the library's validation error instead of raw `ArgumentError`/`BadMapError`, and add per-item map bounds for `:list_map`. Verify with edge tests for scalar-for-string, scalar-for-list, and oversized `:list_map` items.
- [x] 2.9 Guarantee one terminal stream frame on completion, timeout, and abnormal producer death, and emit stream stop/exception events. Verify with `test/phoenix_gen_api/executor/` stream tests asserting the terminal frame in all three cases.
- [x] 2.10 Document execution isolation, hard timeouts, retry outcome, and stream termination in `guides/architecture.md` and `guides/concepts.md`. Verify the sections describe the tested behaviour.

## 3. Worker pool

- [x] 3.1 Make `:DOWN` the single task-completion source, remove the task `after` notification, and ignore completion for unknown or already-idle workers. Verify with a pool test asserting one completion per task and no duplicate dispatch (`refute_receive` a second dispatch).
- [x] 3.2 Enforce the concurrency limit under mixed success/failure completions. Verify with a test that tracks concurrent `:task, :start`/`:stop` pairs and never observes more in-flight tasks than the pool size.
- [x] 3.3 Trap exits in the pool, treat worker `:EXIT` like `:DOWN`, replace the worker, keep the queue, and emit a worker-restart event. Verify with a test that kills a worker while tasks are queued and asserts all queued tasks still complete.
- [x] 3.4 Guard worker respawn failures with a logged, retried path instead of a crash-on-match. Verify with a test that simulates a failing `Worker.start_link/1` and asserts the pool survives.
- [x] 3.5 Withhold circuit-open workers for the cooldown and return a distinct rejection to callers instead of accepting and discarding work. Verify with a worker/pool test that a task sent during cooldown is reported as rejected and not silently completed.
- [x] 3.6 Pop idle workers from the maintained idle list and remove the redundant `MapSet.to_list`/`List.delete` work. Verify with a pool test asserting identical dispatch behaviour and a micro-benchmark showing dispatch no longer allocates with pool size.
- [x] 3.7 Cancel per-task timeout timers on completion and consume the timer on timeout, with no stale messages. Verify with a test that completes a task early and refutes a later `:task_timeout` message.
- [x] 3.8 Make pool status truthful: exclude dead workers and record task failures in the pool-level counter. Verify with a status test after a worker death and after failed tasks.
- [x] 3.9 Route stream tasks to the running stream pool and release the pool slot once stream ownership is handed off. Verify with a test asserting stream tasks occupy stream-pool capacity and that async capacity is unaffected under stream saturation.
- [x] 3.10 Document pool guarantees (single completion, crash containment, circuit behaviour, stream isolation) in `guides/architecture.md` and `guides/diagnostics.md`. Verify the documented guarantees match the new tests.

## 4. Rate limiting

- [x] 4.1 Publish the effective limits snapshot (`:persistent_term`) from `init/1` and every mutation handler, and short-circuit checks when no limits apply. Verify with a test that no limiter call occurs with no limits configured and that runtime limit changes take effect without restart.
- [x] 4.2 Send only the key material the limiter needs instead of the full request, including key material only when a configured limit uses it. Verify with a test asserting the limiter receives the minimal map and decisions are unchanged.
- [x] 4.3 Replace the `{key, [timestamps]}` representation with per-timestamp `:ordered_set` rows, counting via `:ets.select_count` and expiring via `:ets.select_delete`, keeping the `max_requests` bound. Verify with rate-limiter tests for window accuracy and a memory/row-count test.
- [x] 4.4 Route keys by `phash2(key)` regardless of strategy, warn when `:random` is configured, and prove no lost updates under concurrency. Verify with a concurrent burst test that admitted requests never exceed the configured limit.
- [x] 4.5 Catch `:exit` (timeout, `:noproc`, shutdown) in all check paths and apply the configured fail mode with the reason recorded. Verify with tests that kill or stall a limiter instance and assert allow/deny per `:fail_open`.
- [x] 4.6 Honour the configured cleanup interval, use runtime limit state for the window, and move the sweep off the reply path with a single shard owner. Verify with a test that a sweep does not block checks and that a runtime-lengthened window keeps valid timestamps.
- [x] 4.7 Gate `set/add/remove/reset/clear/update_config` behind the admin action when admin actions are configured, including direct instance calls. Verify with tests for allowed, denied, and unconfigured cases.
- [x] 4.8 Support `:max_rate_limit_keys` with an overflow bucket and `:max_rate_limit_key_bytes` hashing, and report unsupported `:ip_address` keying at configuration time and per skipped evaluation. Verify with flood, oversized-key, and missing-key-source tests.
- [x] 4.9 Index per-API limits by `{service, request_type}` so a check does not scan all configured limits. Verify with a benchmark across hundreds of configured limits.
- [x] 4.10 Document keying, fail mode, memory bounds, and the new flags in `guides/configuration.md` and `guides/diagnostics.md`. Verify the documented defaults match `config/config.exs`.

## 5. Config distribution

- [x] 5.1 Centralize configuration validation so `ConfigDb.add/update/batch_add`, `ConfigReceiver.push`, and `ConfigPuller.add` all run identical structural and MFA rules. Verify with a matrix test that each entry point rejects the same invalid config.
- [x] 5.2 Validate every invocable MFA (`mfa`, `nodes`, hooks, `permission_callback`, `result_encoder`, pull targets) and preserve the previous config on rejection. Verify with tests per field and an assertion that a prior valid config still serves requests.
- [x] 5.3 Enforce the `:push_config` admin action when admin actions are configured, keep token enforcement when a token is set, and record rejection reasons. Verify with allowed/denied/unconfigured tests and a wrong-token test.
- [x] 5.4 Implement opt-in source binding (`:config_source_binding`, `:service_owners`) with mismatch recording when disabled. Verify with bound/unbound and owner-mismatch tests.
- [x] 5.5 Implement opt-in downgrade rejection with forced-push bypass, comparable-version checks, and the `:allow_client_version` selection policy. Verify with older/equal/non-comparable version tests and client-version-selection tests.
- [x] 5.6 Bound stored versions (`:max_configs_per_service`) and failed-record retention, and schedule the failed-config sweep from a real owner process with lazy table creation. Verify with cap, expiry, and not-started-store tests.
- [x] 5.7 Report pull outcomes truthfully: failure when nothing usable was stored, per-service partial failure with reason, rejection of non-scalar version replies, and status queries served during a pull. Verify with puller tests per scenario.
- [x] 5.8 Distinguish cache unavailable from not-found and emit the lookup failure event, keeping the existing client message for genuine misses. Verify with a stopped-`ConfigDb` test and a genuine-miss test.
- [x] 5.9 Switch `ConfigDb` to `:ordered_set` so un-versioned resolution does not scan all versions; verify all existing config-cache tests pass and record the benchmark delta against the 1.1 baseline.
- [x] 5.10 Add failure boundaries to `ConfigReceiver` and `ConfigDb` mutations so unexpected input returns an error and telemetry rather than restarting the store. Verify with malformed-push tests asserting state survives.
- [x] 5.11 Validate `ConfigPuller` targets (`:protect_config_puller`, node allowlist, MFA safety) and reject unsafe pull registrations. Verify with tests for each rejection and for the unchanged default path.
- [x] 5.12 Document push authentication, provenance, versioning, retention, and pull failure reporting in `guides/configuration.md` and `guides/architecture.md`. Verify the new flags and defaults are listed.

## 6. Runtime security

- [x] 6.1 Replace the token comparison with a fixed-length digest comparison and keep `valid_push_token?/1` semantics. Verify with `test/phoenix_gen_api/security_test.exs` plus a test asserting identical work for short and long candidates.
- [x] 6.2 Extend the built-in denylist to the documented dangerous Elixir and Erlang modules and keep allowlist matching exact. Verify with security tests for denylisted modules, prefix lookalikes, and explicit allowlist escape.
- [x] 6.3 Apply the admin gate inside the owning processes for every privileged mutation (config push, limiter administration, error detail, tracing) when admin actions are configured. Verify with direct-call tests for each action.
- [x] 6.4 Implement `:require_authenticated_roles` in the channel macro so payload roles are ignored when enabled, preserving current behaviour when disabled. Verify with channel tests for enabled/disabled and for role-based permission checks.
- [x] 6.5 Implement `:reject_unverified_user_id` so an unverified payload identifier is treated as absent when enabled. Verify with permission tests for `:any_authenticated` and `{:arg, "user_id"}`.
- [x] 6.6 Replace configuration-driven `String.to_atom` lookups in `NodeSelector` (and equivalents elsewhere) with existing-atom resolution. Verify with a test that distinct unknown sticky keys do not grow the atom table.
- [x] 6.7 Implement `:protect_internal_tables`: named tables become `:protected` with owner-process writes, and documented module APIs keep working. Verify by driving each module's public API with protection on and an unrelated write rejection test.
- [x] 6.8 Gate tracing control behind the admin action when configured and add `:trace_capture_args` so argument values can be omitted from trace records. Verify with tracer tests for gated control, redacted capture, and unchanged default.
- [x] 6.9 Document the security model, the new flags, the recommended production set, and the deferred default flips in `guides/configuration.md` and `guides/getting_started.md`. Verify the recommended set is copy-pasteable and matches implemented flag names.

## 7. Relay

- [x] 7.1 Implement `:relay_trust_mode` (`:legacy` default, `:strict`): verify actors against the authenticated caller and require admin for group creation/deletion. Verify with tests for matching/mismatching actors and unconfigured legacy behaviour.
- [x] 7.2 Reject non-local PIDs for local groups when local-only enforcement is enabled, and reject membership changes without an authorized actor. Verify with remote-pid and unauthorized-actor tests.
- [x] 7.3 Implement `:relay_limits` for group size, message bytes, and recipient count with explicit rejection reasons. Verify with per-limit tests and an unset-limits compatibility test.
- [x] 7.4 Wrap relay mutations so invalid input or transitions return an error without terminating the server, and assert existing groups survive. Verify with malformed-transition tests that re-read group state afterwards.
- [x] 7.5 Maintain a monitor index so `:DOWN`, leave, delete-group, and re-join all release monitors exactly once. Verify with monitor-count tests and `refute_receive` on stale `:DOWN` after re-join.
- [x] 7.6 Return a recipient snapshot so fan-out runs in the caller, and keep unrelated group operations responsive during a large fan-out. Verify with a concurrency test that creates/joins/messages another group during fan-out.
- [x] 7.7 Report targeted recipients separately from delivered recipients and emit relay accepted/delivered/rejected events. Verify with a test mixing live and dead member pids.
- [x] 7.8 Return unavailable (not an exit) when the relay process is absent. Verify with a test that stops the relay and calls each public operation.
- [x] 7.9 Document relay trust mode, limits, delivery semantics, and isolation in `guides/relay_messages.md`. Verify the guide matches the implemented defaults.

## 8. Integration verification and release notes

- [x] 8.1 Run the full suite (`mix test`), `mix format --check-formatted`, and `mix credo --strict` if configured; verify green with no new warnings.
- [x] 8.2 Re-run `mix run scripts/benchmark.exs` and record per-scenario deltas against the 1.1 baseline, confirming the config lookup, limiter fast path, argument list, and idle-worker dispatch improvements.
- [x] 8.3 Verify backward compatibility with a smoke run that exercises sync, async, stream, permission, rate-limited, and relay requests under default configuration; confirm response shapes and message text are unchanged except the documented retry-exhaustion message.
- [x] 8.4 Update `CHANGELOG.md` with fixed defects, performance numbers, denylist additions, new telemetry events, new flags, and the deferred secure-default flips.
- [x] 8.5 Run `openspec validate harden-library-runtime --strict` and confirm the change validates before archiving.
