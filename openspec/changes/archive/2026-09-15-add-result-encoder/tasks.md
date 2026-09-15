## 1. FunConfig field

- [x] 1.1 Add `result_encoder: {module(), atom(), [any()]} | nil` to the `%__MODULE__{}` type (after `hook_timeout`), `result_encoder: nil` to the defstruct, and one moduledoc line documenting the contract (encoder sees only `data`; must return the encoded value; raise to signal failure; applied to `{:ok, data}` success results only; `:stream` not encoded). Verify with `mix compile` (warnings would surface type errors).
- [x] 1.2 Add `valid_result_encoder?/1` (mirror `valid_hook?/1` at fun_config.ex:539) and its entry in `validate_with_details/1` validations list. Verify: `mix test test/phoenix_gen_api/structs/fun_config_test.exs` still green, then add the validation tests in group 3.

## 2. Executor encoding

- [x] 2.1 Add `apply_result_encoder/2` with three function-head clauses (nil → pass-through; `{:ok, data}` → encode and re-wrap `{:ok, encoded}`; everything else → pass-through) and `encode_result` helper using `try/rescue/catch` → `{:error, "result encoding failed: ..."}` per design D3/D4, applying `Security.validate_mfa` on the encoder MFA per design D5. Insert the call in `do_call` between the retry result (executor.ex:559) and `handle_call_result` (executor.ex:561). Verify with `mix compile`.
- [x] 2.2 Confirm the encoded path is shared: trace that `:async` and `:none` go through `do_call` via `sync_call` and that `:stream` (`stream_call`, executor.ex:1041) does not touch the new code. Verify by reading the call graph and the group 3 async test.

## 3. Tests (test/phoenix_gen_api/executor/)

- [x] 3.1 Test: sync endpoint with `result_encoder: {TestCodec, :encode, []}` returning `{:ok, %TestStruct{}}` → `%Response{success: true, result: encoded}`; encoder receives only the unwrapped `data` (assert arg captured by the test codec). Covers spec "Encoder applied to successful results only" scenarios 1 and 3.
- [x] 3.2 Test: mfa returns `{:error, "order not found"}` with an encoder configured → error response carries the original reason and the encoder was never called. Covers spec "Error result not encoded".
- [x] 3.3 Test: encoder raises (e.g. `{Nonexistent, :func, []}`) → `%Response{success: false}` with an encoding-failure message, calling process alive (`Process.alive?(self())` after call). Covers spec "Encoder failure becomes an error response".
- [x] 3.4 Test: async endpoint (`response_type: :async`) with encoder → async receiver gets the encoded result. Covers spec "Encoder covers sync, async, and none response types".
- [x] 3.5 Test: denylisted encoder module (e.g. `{Code, :eval, []}`) → error response, encoder not applied. Covers spec "Encoder MFA security-validated".
- [x] 3.6 Test: `nil` `result_encoder` → response identical to pre-existing behavior (result passes through unchanged). Covers spec "Nil encoder passes through".
- [x] 3.7 Test in `test/phoenix_gen_api/structs/fun_config_test.exs`: `validate_with_details` accepts `{mod, fun, []}`, rejects `{:list, :map}` and non-tuple values, and defaults to `nil` when unset. Covers spec "FunConfig result_encoder field".
- [x] 3.8 Run full suite `mix test` and `mix format --check-formatted`; confirm no regressions and stream tests untouched.

## 4. Release prep

- [x] 4.1 Bump version in `mix.exs` (2.23.1 → 2.24.0, minor: additive public field) and confirm `mix compile` + `mix test` pass.
