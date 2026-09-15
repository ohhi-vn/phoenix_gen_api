# Design: Clean Docs & Guides for Newbies

## Context

10 guides (~6,800 lines) + README, all discovered by ExDoc's glob `extras()` in `mix.exs`, plus one verified library defect in ImplHelper (see D9) (no `groups_for_extras`, default page = Getting Started). Verified problems (see proposal.md - Why): getting_started is broken against current `use PhoenixGenApi` defaults, three files are near-total duplicates of others, `result_encoder` is absent from guides. One existing spec (`fun-result-encoder`) is unaffected — this is docs-only.

## Goals / Non-Goals

**Goals:**
- One identity per file: entry point (README) → on-ramp (concepts) → critical path (getting_started) → endpoint reference (fun_config) → app config (configuration) → feature (relay_messages) → observability (telemetry, diagnostics) → internals (architecture).
- Every code sample in rewritten/absorbed content verified against current source behavior.
- Correctness first: fix the auth breakage and version rot before style work.

**Non-Goals:**
- No doc-test infrastructure, no CI docs validation (could be follow-ups).
- No ExDoc `groups_for_extras` reorganization or navigation polish (deferrable; glob discovery keeps working).
- No translation, no new deep-dive content beyond the absorbing moves.

## Decisions

- **D9 — Fix the ImplHelper encoder contract violation (added after task-2.1 verification exposed it).** The generated impl must satisfy the encoder protocol contract (`encode/2` → iodata for `Jason.Encoder`/`JSON.Encoder`). Fix: `encode(data, opts) do data |> module.encode!(opts) |> encoder.encode(opts) end`. Macro mechanics learned during verification: (a) `bind_quoted` injects `var!(name) = Macro.escape(value)` assignments whose bindings do NOT propagate into defimpl module bodies — plain `unquote` of already-resolved literals is required; (b) `__using__` receives `opts` as AST, so options are evaluated via `Code.eval_quoted(opts, [], __CALLER__)` at macro-expansion; (c) `gen_impl` args are alias ASTs — `Macro.expand(encoder, __CALLER__)` resolves them; (d) consumers of a changed macro (channels doing `use PhoenixGenApi`) are not auto-recompiled when only the macro source changes — `mix deps.compile phoenix_gen_api --force` plus consumer recompile is needed during verification. Tests asserting the old contract are updated, not silenced. Alternative considered: documenting an app-level `defimpl` workaround — rejected, unacceptable for a newbie-focused guide and it papers over a wire-level bug.
- **D1 — Solo-node quick start before the two-node split.** FunConfig execution against the node's own address (`nodes: [Node.self()]`) routes through the executor's remote/rpc path, which auto-loads lazily-loaded modules and works on a non-distributed node — proven in the scratch app. `nodes: :local` fails on a fresh boot because the executor's local path uses `function_exported?/3` (executor.ex:617) and BEAM loads modules lazily — the guide must teach `nodes: [Node.self()]` for the solo phase (same shape as the two-node config). Alternative: `:local` + `Code.ensure_loaded` boilerplate — rejected, extra concept with no benefit.
- **D2 — Fix the auth breakage by teaching it, not hiding it.** `require_verified_user_id: true` is the secure default; the guide's socket shows the minimal `connect/3` change assigning `user_id` from connect params, and mentions `require_verified_user_id: false` explicitly as the "public demo" escape hatch in Troubleshooting. Alternative: silently disable it in the guide's config — rejected, it teaches insecure config by example.
- **D3 — Absorb feature sections into `fun_config.md` rather than keeping a slimmed step_by_step.** step_by_step's §2-11 are all aspects of configuring a FunConfig; fun_config.md already owns the arg_types/permission/version tables, so the how-to prose lands next to the tables it complements. Keeps file identity clean (endpoint reference owns all endpoint-configuration topics). Alternative: slim step_by_step holding only feature walkthroughs — rejected, preserves the mixed-identity file we're trying to remove.
- **D4 — Testing section goes into getting_started's closing "Where to go next" area** (short: ExUnit test of a Supporter + `Executor.execute!` against a local config). It's entry-level; architecture would bury it.
- **D5 — `execute_flow.md` merges into architecture.md as a "Line-by-line execution" section** after its "Request Lifecycle". Zoom levels stack: overview diagram → phase table → line-by-line. Duplicate content (the two lifecycle diagrams) is consolidated; keep the richer of each pair.
- **D6 — `tracing.md` merges into `diagnostics.md`** — both answer "what is happening at runtime"; diagnostics keeps IEx helpers/health checks, gains tracing as a section. Telemetry stays separate (it's a metrics/event reference, not debugging).
- **D7 — Absorbed sections move nearly verbatim** with light connective editing (to fit new neighbors, fix dep pins, fix auth examples). No wholesale rewriting — limits review surface and preserves already-good content.
- **D8 — Cross-links updated in the same task**, including `mix.exs` `extras()` title-mapping (drop the three dead case clauses — optional cosmetic, zero-risk).

## Risks / Trade-offs

- [Absorbed sections drift while editing] → D7 nearly-verbatim moves; final pass re-runs each code sample mentally against source (`executor.ex`, `argument_handler.ex`, `lib/phoenix_gen_api.ex:1542`).
- [Deleting step_by_step loses searchability of its URL on Hexdocs] → Hexdocs URLs for deleted pages break; mitigate with redirects impossible in ExDoc — accepted, low traffic cost for a 2.24-era lib; CHANGELOG note.
- [getting_started rewrite drifts from reality] → samples verified in IEx where feasible (solo-node path is runnable in dev).
- [fun_config.md grows large (~500 lines)] → acceptable: it is the endpoint reference; TOC keeps it navigable.
- [Custom encoder protocols (e.g. ToonEx.Btoon in production gateways) now get recursive encoding] → generated impls call `encoder.encode/2` on the `encode!/2` output; production apps must re-verify their custom Encoder implements the protocol for plain maps (it does if it is a real encoder protocol). CHANGELOG call-out.

## Migration Plan

The ImplHelper fix lands first (it changes runtime behavior of generated impls), then docs. Rollback: git revert per commit; the fix's nil-equivalent rollback is reverting impl.ex (old behavior identical to pre-2.24 wire behavior minus the crash). Order: correctness fixes (getting_started auth + README rot) land first in tasks, then merges, then deletions — so links are never redirected to content that hasn't moved yet.

## Open Questions

None.
