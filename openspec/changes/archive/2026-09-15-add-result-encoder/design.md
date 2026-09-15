## Context

The executor builds every sync/async/none response through `do_call/2` (executor.ex:517), which ends with the mfa result flowing into `handle_call_result/2` (:966). `handle_call_result` routes `{:error, reason}` to an error Response and other shapes to success Responses. Async requests funnel through `async_call/2` (:991) → `sync_call/2` (:471) → `do_call`, so one insertion point covers all three response types. `:stream` goes through a separate `StreamCall` GenServer (executor.ex:1041).

`FunConfig` (structs/fun_config.ex) already carries a similar MFA-shaped field pattern: `before_execute`/`after_execute` hooks validated by `valid_hook?/1` (:539) inside `validate_with_details/1` (:274). Security for MFAs is centralized in `Security.validate_mfa/1` (denylist + optional allowlist), applied to the endpoint's own mfa in `execute_local` (executor.ex:566).

## Goals / Non-Goals

**Goals:**
- Encode successful response payloads at the framework boundary, once, for sync/async/none
- Guarantee the channel process never crashes on an encoder failure
- Keep error responses byte-identical to today's behavior
- Reuse the existing FunConfig validation and Security patterns

**Non-Goals:**
- Encoding stream chunks (`StreamCall` path) — possibly later, separate change
- Wrapping encoders for the downstream ash_phoenix_gen_api transformer (that repo consumes this in a later release)
- Applying the encoder to non-`{:ok, data}` success shapes (plain values, other tuples) — they pass through with today's existing warning/logging behavior

## Decisions

### D1: Single insertion point in `do_call` between the retry result and `handle_call_result`
Covers sync, async, and `:none` because they all funnel into `do_call`. Alternative considered: encode inside `handle_call_result` — rejected, that function also serves the error path and stream-adjacent flow; a dedicated gate keeps the contract explicit.

### D2: Encoder sees only `data`, not the `{:ok, data}` tuple
The gate pattern-matches `{:ok, data}`, applies `apply(mod, fun, [data | args])`, and re-wraps the return as `{:ok, encoded}`. Rationale: the encoder's domain is the payload, not the result envelope; passing the envelope would force every encoder to match on it. Alternatives considered: passing the raw tuple (rejected — leaks the envelope); encoding only non-error raw values without unwrapping (rejected — same leak).

### D3: Contract is "return the encoded value; raise to signal failure"
The executor wraps whatever the encoder returns as `{:ok, encoded}`. An encoder that deliberately returns `{:error, reason}` would be wrapped as `{:ok, {:error, reason}}` (a success containing an error shape), so the moduledoc documents raising as the failure mechanism; rescue/catch turns it into `{:error, "result encoding failed: ..."}` → error response. Alternative considered: letting the encoder return `{:error, reason}` as a failure signal — rejected, ambiguous with legitimate encoded payloads that happen to look like error tuples.

### D4: Gate is a function-head pattern match, not an `if`
```elixir
defp apply_result_encoder(%FunConfig{result_encoder: nil}, result), do: result
defp apply_result_encoder(fun_config, {:ok, data}), do: {:ok, encode_result(...)}
defp apply_result_encoder(_fun_config, result), do: result
```
The final clause is the pass-through for `{:error, _}` and every other shape. Mirrors the codebase's pattern-matching style; no conditional nesting.

### D5: Encoder MFA passes through `Security.validate_mfa`
Same check the endpoint's own mfa gets in `execute_local`. Keeps denylist (`:code`, `:erlang`, `:rpc`, ...) and optional `:mfa_allowlist` consistent — otherwise `{Code, :eval, []}` as an encoder would bypass the guard protecting the mfa it wraps. Cost: negligible (existing ETS-backed check). Consequence: allowlist deployments must include the encoder MFA — a visible, immediate config error rather than a silent inconsistency.

### D6: Structural validation mirrors `valid_hook?/1`
`nil` is valid; `{atom, atom, list}` is valid; anything else is rejected with a message naming `result_encoder`. Placed in `validate_with_details/1` alongside the existing validations. Alternative considered: running `Security.validate_mfa` at config-validation time — rejected, validation stays pure/structural there; runtime security check belongs in the executor alongside the existing one.

### D7: `:none` response type still encodes
Result is discarded, so encoding is wasted work, but branching to skip it adds a special case for no observable benefit. Harmless by design (encoder failure still can't crash anything — response is discarded).

## Risks / Trade-offs

- [:mfa_allowlist deployments without the codec MFA] → requests fail visibly with an mfa_not_allowed error; migration note in the moduledoc covers it. Rollback is removing the `result_encoder` field from config (nil default restores old behavior).
- [Remote services: structs cross erpc to the gateway, where the codec runs] → the encoded struct's module must be loaded on the gateway node; same-release gateway/service clusters satisfy this. Different-release deployments with unshared struct modules will see encoder failures surfaced as error responses (D3's rescue), not crashes.
- [Encoder returning a shape that `handle_call_result` treats as unexpected, e.g. a 3-tuple] → wrapped as `{:ok, 3-tuple}` → success response containing the tuple; matches today's behavior for such results. Documented contract in moduledoc.
- [`result_encoder` set on a `:stream` endpoint is silently ignored] → documented explicitly in the moduledoc and spec (stream not encoded).

## Migration Plan

Additive field defaulting to `nil` — no existing config or cached struct changes meaning. Old configs build with `result_encoder: nil`. Rollback: set the field to `nil` or revert to a prior release; behavior is identical to 2.23.x for nil encoders.

## Open Questions

(none)
