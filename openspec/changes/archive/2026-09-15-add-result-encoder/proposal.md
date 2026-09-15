## Why

FunConfig endpoints can only return raw mfa results — there is no way to shape the payload (e.g. convert structs to JSON-safe maps) at the framework boundary. Downstream consumers must duplicate encoding logic per endpoint or accept leaked internal shapes. A configurable per-endpoint result encoder fixes this at the single point where every sync/async response is built, and turns encoder failures into error responses instead of channel crashes.

## What Changes

- Add a `result_encoder: {module(), atom(), [any()]} | nil` field to `FunConfig` (defaults to `nil`), with structural validation mirroring the existing hook validator and a moduledoc entry.
- Add executor support that applies the encoder between the mfa result and `handle_call_result`, covering sync, async, and `:none` response types through one insertion point in `do_call`.
- Contract: the encoder is applied only to successful results — the `{:ok, data}` tuple is unwrapped and the encoder receives only `data` as its first argument (`apply(mod, fun, [data | args])`). Error tuples and other shapes pass through untouched.
- Encoder failures (raise/throw/exit) are rescued and become `{:error, "result encoding failed: ..."}` → error response; the channel process never crashes.
- The encoder MFA passes through `Security.validate_mfa` like the endpoint's own mfa (denylist + optional allowlist).
- Stream responses (`:stream` via `StreamCall`) are out of scope and remain unencoded, documented as such.

## Capabilities

### New Capabilities

- `fun-result-encoder`: Per-endpoint result encoding in the executor — FunConfig configuration/validation of the encoder MFA, the `{:ok, data}`-only application contract, pass-through of error results, failure-to-error-response behavior, and Security validation of the encoder MFA.

### Modified Capabilities

(none — no existing specs)

## Impact

- `lib/phoenix_gen_api/structs/fun_config.ex` — new field, type, defstruct default, validator, moduledoc.
- `lib/phoenix_gen_api/executor/executor.ex` — new `apply_result_encoder/2` + `encode_result` helpers, one call site in `do_call`.
- Public API surface: new `FunConfig` field (additive, backward compatible — defaults to `nil`).
- Security note: deployments using `:mfa_allowlist` must include the encoder MFA or requests fail visibly.
- Downstream (ash_phoenix_gen_api) can consume this in a later release; not part of this change.
