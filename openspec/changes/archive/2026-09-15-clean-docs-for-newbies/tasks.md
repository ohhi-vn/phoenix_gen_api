# Tasks: Clean Docs & Guides for Newbies (+ ImplHelper Encoder Fix)

## 1. ImplHelper Encoder Fix

- [x] 1.1 Rework `lib/phoenix_gen_api/helpers/impl_helper/impl.ex`: `__using__` evaluates opts at macro-expansion (`Code.eval_quoted(opts, [], __CALLER__)`) and generates per-module defimpl quotes with plain `unquote` (no `bind_quoted`); `gen_impl` expands args via `Macro.expand(__CALLER__)`. The generated `encode/2` applies `module.encode!(opts)` then `encoder.encode(encoded, opts)`. Verify: `mix compile` clean.
- [x] 1.2 Update tests asserting the old contract in `test/phoenix_gen_api/impl_helper/impl_helper_test.exs`, `test/phoenix_gen_api/internal_impl_test.exs` and any other failing tests: add a Map impl for the test protocol where needed, assert nested/top-level/list encoding produce protocol-encoded output. Verify: full `mix test` green.
- [x] 1.3 End-to-end wire proof in a scratch `mix phx.new` app using the lib as a path dep: channel with `use PhoenixGenApi, event: "api"`, socket assigning `user_id` from connect params, configs registered via `PhoenixGenApi.ConfigDb.add` with `nodes: [Node.self()]`; real websocket client joins and pushes `get_user`; assert the response JSON object arrives on the event with no channel crash. Verify: response received, 0 channel crashes in log.
- [x] 1.4 Record discovered facts for guide tasks: `arg_orders` required when `arg_types` set; `choose_node_mode`/`response_type` have no defaults (nil fails validation); errors masked as "Internal Server Error" unless `detail_error: true`; Phoenix socket transport requires `vsn=2.0.0`.

## 2. Correctness Fixes First

- [x] 2.1 Fix `guides/getting_started.md` auth breakage: update the UserSocket `connect/3` example to assign `user_id` (with note on `require_verified_user_id` default `true` at `lib/phoenix_gen_api.ex:1551`), and mention `require_verified_user_id: false` as the public-demo option. Verify: guide code paths match the scratch app's proven setup.
- [x] 2.2 Fix version rot: README version line 2.18.0 → 2.24.0 and both `~> 2.16` dep pins (README + getting_started) → current. Verify: `grep -n "2.18\|~> 2.16" README.md guides/*.md` returns no stale entries.

## 3. Rewrite Getting Started (solo-node first)

- [x] 3.1 Restructure `guides/getting_started.md`: Phase 1 = single `mix phx.new` project with one `nodes: [Node.self()]` FunConfig and browser JS client working in ~2 minutes (verified setup from task 1.3). Phase 2 = split into gateway + service nodes reusing the same FunConfig, introducing libcluster/supporter/pull. Verify: build it once in a scratch project before committing text.
- [x] 3.2 Add Troubleshooting section to getting_started: "Authentication required" (#1), unsupported function/config not found, node not connected. Verify: each entry names the error string the lib actually emits.
- [x] 3.3 Add short Testing section (from step_by_step §15): ExUnit test of a Supporter returning configs + `Executor.execute!` against a registered FunConfig, plus a ChannelCase test; note `detail_error: true` for meaningful error assertions. Verify: sample test compiles and passes against the scratch app's proven test setup.

## 4. Create Concepts Guide

- [x] 4.1 Write `guides/concepts.md` (short): gateway vs service node, FunConfig, supporter, pull vs push, Request/Response, node selection — one diagram + one paragraph each; link from getting_started and README. Verify: renders in `mix docs` output; each diagram is plain ASCII.

## 5. Absorb Step-by-Step Feature Sections into fun_config.md

- [x] 5.1 Absorb §2 Argument Validation into `guides/fun_config.md` arg_types section (nearly verbatim per design D7). Verify: no duplicate tables; examples match `argument_handler.ex` behavior (incl. empty `arg_orders` + single-arg case).
- [x] 5.2 Absorb §3 Permissions how-to next to the permission-modes table; keep teaching `require_verified_user_id` consistently with 2.1. Verify: permission examples match `permission.ex`.
- [x] 5.3 Absorb §8 Versioning, §9 Retry, §10 Node Selection, §11 Hooks into the matching fun_config.md sections; add `result_encoder` field row to the schema table (contract: encoder sees `data` only, `{:ok, data}` results only, `:stream` not encoded, per `fun_result_encoder` spec). Verify: schema table matches `lib/phoenix_gen_api/structs/fun_config.ex` defstruct exactly, defaults reflect validation requirements.
- [x] 5.4 Drop configuration.md's duplicated "Function Versioning" section (fun_config.md now owns it); update its What's Next links. Verify: `grep -in "versioning" guides/configuration.md` shows only the removal-clean state.

## 6. Merge Deep Guides

- [x] 6.1 Merge `guides/execute_flow.md` into `guides/architecture.md` as "Line-by-line execution" after Request Lifecycle; consolidate duplicate lifecycle diagrams (keep the richer of each pair). Verify: architecture.md has no two diagrams of the same flow; all execute_flow content has a home or was intentionally dropped (list drops in change log).
- [x] 6.2 Merge `guides/tracing.md` into `guides/diagnostics.md` as a Tracing section. Verify: tracing's API list matches `lib/phoenix_gen_api/tracer.ex` public functions.

## 7. Delete and Relink

- [x] 7.1 Delete `guides/step_by_step_guide.md`, `guides/execute_flow.md`, `guides/tracing.md`. Verify: `ls guides` shows exactly 7 files.
- [x] 7.2 Update all cross-links (README, remaining guides) so no link targets a deleted file; drop the three dead title-mapping case clauses in `mix.exs` `extras()`. Verify: `grep -rn "step_by_step_guide\|execute_flow\|tracing.md" README.md guides/ mix.exs` returns nothing; `mix docs` builds clean.

## 8. Final Verification

- [x] 8.1 Run `mix docs` and click through the guide chain: README → getting_started → concepts → fun_config → telemetry/diagnostics/architecture; every link resolves and every new/edited code sample matches current source. Verify: build succeeds with no dead links flagged; spot-check the solo-node quick start one final time in a scratch project.
- [x] 8.2 Add CHANGELOG entry describing the ImplHelper fix (with custom-encoder re-verification call-out) and the guide restructure with the three deleted pages. Verify: CHANGELOG top entry mentions both.
