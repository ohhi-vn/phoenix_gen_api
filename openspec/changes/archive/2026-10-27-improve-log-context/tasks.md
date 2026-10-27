# Tasks

## 1. Log context foundation

- [x] 1.1 Create `PhoenixGenApi.LogContext` with the canonical key list, `event/2` line builder, `request_context/2`, `value/1`, `put/1`, `with_context/2` (restoring via `Logger.reset_metadata/1`), and `payload/1` that returns a redacted placeholder unless `:log_verbose_payloads` is `true`; add unit tests in `test/phoenix_gen_api/log_context_test.exs` covering formatting, nil handling, nested context restoration, and verbose gating.
- [x] 1.2 Add the `log_verbose_payloads` option (default `false`) with a comment to `config/config.exs` and document it in `guides/configuration.md`; verify the documented default matches the code by reading the generated config section back.
- [x] 1.3 Add the logging-context section to `guides/diagnostics.md`: key vocabulary (`event`, `request_id`, `request_type`, `service`, `user_id`, `node`, `version`, `origin_node`), the `[Module] event=...` format rule, and a copy-paste Logger formatter snippet that renders `$metadata`; verify the snippet compiles by running `mix run -e 'IO.puts(:ok)'` with it temporarily applied in a scratch script.
- [x] 1.4 Add `@derive {Inspect, except: [:push_token]}` to `PhoenixGenApi.Structs.PushConfig` and a test asserting `inspect/1` never contains the token; add it to the existing `test/phoenix_gen_api/structs/push_config_test.exs` and verify with `mix test test/phoenix_gen_api/structs/push_config_test.exs`.
- [x] 1.5 Add a CHANGELOG entry summarizing context enrichment, level changes, and token redaction; verify it names the new config key and the breaking-free compatibility note.

## 2. Entry-point context installation and propagation

- [x] 2.1 Install coarse context in `PhoenixGenApi.__using__/handle_in` (raw payload `request_id`, `request_type`, `service`, `user_id`, channel module, current node) with restore after the request; extend `test/phoenix_gen_api/phoenix_gen_api_test.exs` so a decode-failure log line contains those fields.
- [x] 2.2 Install authoritative request context in `Executor.execute!/1` outside `Tracer.begin_trace/1` and restore it in `after`; add a test in `test/phoenix_gen_api/executor/executor_test.exs` asserting metadata is absent after `execute!/1` returns and present during a logged error.
- [x] 2.3 Replace the tracer-only metadata copy in `Executor.async_call/2` and `Executor.stream_call/2` with a shared capture/apply/restore helper, and apply the same pattern in `PhoenixGenApi.StreamCall` and worker-pool task execution; add a worker-reuse test proving a second request does not inherit the first request's `request_id`.
- [x] 2.4 Update `ChannelHelpers` result `handle_info` clauses to log `event=`, `request_id`, `request_type`, and payload size instead of full result inspection unless verbose payloads are enabled; extend `test/phoenix_gen_api/helpers/channel_helpers_test.exs` to assert no payload contents appear by default.

## 3. Request path log enrichment

- [x] 3.1 Convert every `Logger.*` call in `lib/phoenix_gen_api/executor/executor.ex` to include `event=`, request identity, `service`, `request_type`, and `node` where applicable; name `failed_node` on RPC fallbacks and add the MFA on dispatch failures. Verify with a new `test/phoenix_gen_api/executor/executor_logging_test.exs` capturing an unsupported-function line, a remote-fallback line, and a retry-exhausted line.
- [x] 3.2 In `Executor`, demote remote/local retry attempt logs from `info` to `debug`, and build retry context once per retry state instead of per interpolation; verify the retry tests assert level `:debug` and the message still contains `remaining` and `backoff_ms`.
- [x] 3.3 Enrich `PhoenixGenApi.StreamCall` lines with `event=`, request identity, and `service`; verify with a capture-log test for unknown-message and timeout paths.
- [x] 3.4 Thread request context through `ArgumentHandler` deep validators (`log_and_raise/1`, nested map/list validators, size/required-key validators) so every raise log names `request_type` and `request_id`; demote caller-schema violations from `error` to `warning` and add the offending argument name to all conversion errors. Verify with `test/phoenix_gen_api/argument_handler_test.exs` plus a new assertion set that every captured error/warning contains both keys.
- [x] 3.5 Make argument conversion/dump debug lines lazy (`Logger.debug(fn -> ... end)`) and redact argument values unless verbose payloads are enabled; verify a capture-log test shows `args_size` rather than values by default and full values when the flag is on.

## 4. Config lifecycle log enrichment

- [x] 4.1 In `ConfigReceiver`, derive the pushing node from `from` and install a push context (`service`, `config_version`, `origin_node`) around `do_push/3`; include it on decode failure, validation failure, token rejection, skip, accept, delete, and partial-push lines. Verify with `test/phoenix_gen_api/config_cache/config_receiver_test.exs` asserting `service`, `config_version`, `origin_node`, and `event` on a classic `nodes must be a non-empty list` failure.
- [x] 4.2 On push validation failure, include the count and first N `request_type` values carried by `fun_configs` (bounded list), and keep per-item failures naming each `request_type`; verify a capture-log test with three entries asserts the count and each request type.
- [x] 4.3 Redact push tokens in `validate_push_token/1` and any other line that inspects a `PushConfig`; verify a token-rejection test asserts the token string never appears in the captured log while `service` and `origin_node` do.
- [x] 4.4 Enrich `ConfigPuller` lines so every RPC attempt/outcome names `service`, `node`, and `version` where known, and task-exit lines include the affected service; verify with `test/phoenix_gen_api/config_cache/config_puller_test.exs` capture-log assertions for version-check, RPC fallback, and partial-pull paths.
- [x] 4.5 Enrich `ConfigPusher` RPC-failure lines with `service` and `version` (currently node + reason only) and add `event=` across push/verify/startup lines; verify with `test/phoenix_gen_api/config_cache/config_pusher_test.exs` asserting a failed RPC line names the service and version.
- [x] 4.6 Add `event=` and missing `request_type`/`version` context to `ConfigDb` and `ConfigFailed` lines, replacing full struct dumps in failure logs with the identifying fields; verify with their existing tests plus a capture-log assertion that the invalid-config line contains service, request type, and version.

## 5. Pool, rate limiter, and relay logs

- [x] 5.1 Keep worker-pool-level lines health-focused but add `event=` and the current node; ensure executor rejection lines already carry request identity, and add a test asserting a queue-full rejection is traceable from the executor line.
- [x] 5.2 Include `request_id`, `request_type`, `service`, and `user_id` in `RateLimiter` exceeded/fail-open lines by passing a small context map in the internal check payload; verify with `test/phoenix_gen_api/rate_limiter/rate_limiter_test.exs` capture-log assertions.
- [x] 5.3 Add `event=` and missing group/user/node context to `Relay` and `RelayServer` lines; verify with `test/phoenix_gen_api/relay/relay_test.exs` and `relay_server_extra_test.exs`.

## 6. Security, hooks, selection, and startup logs

- [x] 6.1 Add `event=`, request identity, and node to `Permission` lines that currently name only the callback or node; keep denial reasons intact. Verify with `test/phoenix_gen_api/permission_logging_test.exs` and `permission_extra_test.exs`.
- [x] 6.2 Add request identity and hook target to `Hooks` timeout/crash lines; verify with `test/phoenix_gen_api/hooks_test.exs` and `hooks_extra_test.exs`.
- [x] 6.3 Add request identity (or explicit `request=unknown` for startup calls) and `event=` to `NodeSelector`, `Security`, `Application`, `WorkerPoolSupervisor`, and `Telemetry` lines; verify with `node_selector_test.exs`, `security_test.exs`, and `application_test.exs`.
- [x] 6.4 Ensure no remaining line interpolates a raw `%PushConfig{}`, request payload, argument map, or function result outside the verbose gate; verify with a repository-wide grep for `inspect(config)` / `inspect(payload)` / `inspect(result)` in `Logger` calls and a review of each hit.

## 7. Integration verification

- [x] 7.1 Run `mix precommit` and confirm compilation with warnings-as-errors, formatting, and the full test suite pass.
- [x] 7.2 Run `openspec validate improve-log-context --strict` and confirm every requirement has at least one scenario backed by a test or a documented manual check.
- [x] 7.3 Reproduce the reported incident scenario in a test or `iex -S mix` session: push a `PushConfig` with empty `nodes`, and confirm the log line shows `[ConfigReceiver] event=... service=... config_version=... origin_node=... request_types=...` plus the validation error.

## Workflow follow-up

- Archive the change after review and after `mix precommit` is clean.
- Verify the archived spec at `openspec/specs/log-context/spec.md` contains the final Purpose and requirements.
