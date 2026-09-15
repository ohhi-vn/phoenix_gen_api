# Proposal: Clean Docs & Guides for Newbies (+ ImplHelper Encoder Fix)

## Why

The docs are thorough but not newbie-friendly: the Getting Started guide is broken against current code (`use PhoenixGenApi` defaults to `require_verified_user_id: true`, so every request from the guide's JS client is rejected with "Authentication required" and the guide never mentions it), the set has heavy duplication (`step_by_step_guide.md` duplicates getting_started and four feature guides; `execute_flow.md` duplicates architecture's lifecycle), and `result_encoder` — the newest feature — is documented nowhere outside moduledocs. New features ship without touching guides.

Additionally, the required quick-start verification exposed a real library bug: `ImplHelper.gen_impl` generates encoder protocol impls that violate the encoder contract (`encode/2` returns the raw `encode!/2` map instead of protocol-encoded iodata), and the channel's `use PhoenixGenApi` regenerates this broken impl, overriding the library's own correct impl in `response.ex`. Over a real websocket with standard Jason/JSON config, any sync/async/stream response push crashes the channel process. Phoenix ChannelTest bypasses wire serialization, so the existing test suite never caught it. The rewritten Getting Started guide cannot be truthful without fixing this.

## What Changes

- **Fix `ImplHelper` generated encoder impls (BREAKING for custom encoder protocols)**:
  - `gen_impl`/`__using__` generate impls that conform to the encoder protocol contract: `encode/2` applies the struct's `encode!/2` first, then recursively encodes via the encoder protocol (`encoder.encode(encoded, opts)`), returning iodata as required by `Jason.Encoder` and `JSON.Encoder`.
  - Macro plumbing: options are evaluated at macro-expansion (`Code.eval_quoted` in `__using__`, `Macro.expand` in `gen_impl`); plain `unquote` of resolved literals instead of `bind_quoted` (which injects `var!` assignments that cannot propagate into defimpl bodies).
  - Apps using custom encoder protocols (e.g. a custom JSON library's Encoder) must re-verify: generated impls now recursively encode the `encode!/2` output instead of passing it through.
- **Rewrite `guides/getting_started.md`**:
  - Solo-node quick start first: one project, one `:local` FunConfig, working browser call in ~2 minutes — then a second phase that splits into gateway + service nodes.
  - Fix the auth breakage: explain `require_verified_user_id` (default `true`) and show the user_id assignment, or set `require_verified_user_id: false` for the public demo.
  - Add a Troubleshooting section ("Authentication required" is entry #1).
  - Fix dep pin rot (`~> 2.16` → current).
- **New `guides/concepts.md`** (short): gateway vs service node, FunConfig, supporter, pull/push, Request/Response — one diagram each.
- **Absorb into `guides/fun_config.md`**: step_by_step §2 (argument validation), §3 (permissions how-to), §8 (versioning), §9 (retry), §10 (node selection), §11 (hooks); add the `result_encoder` field row.
- **Absorb `guides/execute_flow.md` into `guides/architecture.md`** as the line-by-line execution walkthrough.
- **Absorb `guides/tracing.md` into `guides/diagnostics.md`** — one runtime-debugging/observability guide.
- **Add a short Testing section** (from step_by_step §15) to getting_started.
- **Fix README rot**: version line 2.18.0 → 2.24.0, dep pin.
- **Delete**: `guides/step_by_step_guide.md`, `guides/execute_flow.md`, `guides/tracing.md`.
- `guides/configuration.md`: drop its duplicated "Function Versioning" section (versioning lives in fun_config.md); update cross-links.
- Update all cross-links between guides (ExDoc `extras()` titles keep working; deleted files' links must be redirected).

Result: 10 guide files → 7, each with one identity: entry point → concepts → endpoint reference → app config → feature → observability → internals.

## Capabilities

### New Capabilities

- `impl-helper-encoder`: ImplHelper-generated encoder protocol implementations conform to the encoder protocol contract — `encode/2` recursively encodes the struct's `encode!/2` output via the encoder protocol, and the generated impls work for nested values over Phoenix channel wire transport.

### Modified Capabilities

(none — `fun-result-encoder` is unaffected)

## Impact

- Files: `README.md`, all 10 `guides/*.md` (3 deleted, 2 absorb content, 2 rewritten/expanded, 1 new, 1 trimmed).
- `mix.exs`: no change needed — `extras()` discovers guides by glob; deleted titles in the title-mapping case may be dropped for cleanliness (optional, harmless if left).
- No code, no API, no dependency changes. Hexdocs output layout changes (fewer guide pages).
- Risk: absorbed content must remain accurate — sections move nearly verbatim with light editing for their new context; verify every code sample against current source (`require_verified_user_id`, `result_encoder`, `arg_orders` semantics).
