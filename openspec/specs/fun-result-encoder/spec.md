# fun-result-encoder Specification

## Purpose

Lets a FunConfig endpoint shape its successful response payload at the framework boundary by configuring a per-endpoint result encoder, applied uniformly to sync and async responses without per-endpoint code duplication.

## Requirements

### Requirement: FunConfig result_encoder field
FunConfig SHALL support a `result_encoder` field that is either `nil` or a valid `{module, function, args}` MFA tuple, and SHALL reject configurations with an invalid value. The field SHALL default to `nil`, and existing configurations without the field SHALL remain valid.

#### Scenario: Valid encoder accepted
- **WHEN** a FunConfig is validated with `result_encoder: {MyCodec, :encode_result, [:map]}`
- **THEN** validation succeeds

#### Scenario: Invalid encoder rejected
- **WHEN** a FunConfig is validated with `result_encoder: {:list, :map}` (not a 3-tuple) or a non-tuple value
- **THEN** validation fails with an error message identifying `result_encoder`

#### Scenario: Backward compatible default
- **WHEN** a FunConfig is built without specifying `result_encoder`
- **THEN** the field is `nil` and validation succeeds

### Requirement: Encoder applied to successful results only
The executor SHALL unwrap a successful `{:ok, data}` mfa result and apply the encoder to `data` as the first argument followed by the encoder's configured args. The executor SHALL NOT apply the encoder to `{:error, reason}` results or any other result shape; those SHALL pass through unchanged. A nil encoder SHALL pass all results through unchanged.

#### Scenario: Sync response encoded
- **WHEN** a sync endpoint's mfa returns `{:ok, data}` and a result_encoder is configured
- **THEN** the encoder is called with `data` and the encoder's args, and the response result is the encoder's return value

#### Scenario: Error result not encoded
- **WHEN** an endpoint's mfa returns `{:error, reason}` and a result_encoder is configured
- **THEN** the encoder is not called and the error response carries the original reason

#### Scenario: Nil encoder passes through
- **WHEN** a FunConfig has `result_encoder: nil`
- **THEN** the response is identical to the pre-existing behavior

### Requirement: Encoder covers sync, async, and none response types
The encoder SHALL be applied identically for `:sync`, `:async`, and `:none` response types, through the single execution path shared by those types. Encoded async results SHALL be delivered to the async receiver in the same way as unencoded ones.

#### Scenario: Async response encoded
- **WHEN** an async endpoint's mfa returns `{:ok, data}` and a result_encoder is configured
- **THEN** the async response result is the encoder's return value

#### Scenario: None response type does not crash
- **WHEN** a `:none` endpoint's mfa returns `{:ok, data}` and a result_encoder is configured
- **THEN** execution completes without raising

### Requirement: Encoder failure becomes an error response
If the encoder raises, throws, or exits, the executor SHALL return an error response with a message describing the encoding failure instead of propagating the error to the calling process. The original `{:error, reason}` failure path SHALL be unaffected by encoder configuration.

#### Scenario: Encoder crash contained
- **WHEN** a configured encoder raises (e.g. an undefined function)
- **THEN** the response is an error response with an encoding-failure message, and the calling process remains alive

### Requirement: Encoder MFA security-validated
The executor SHALL validate the encoder MFA through the same MFA security check applied to the endpoint's own mfa before applying it.

#### Scenario: Denylisted encoder module rejected
- **WHEN** a result_encoder names a module on the hardcoded denylist (e.g. `Code`)
- **THEN** the response is an error response and the encoder is not applied

#### Scenario: Allowlisted encoder accepted
- **WHEN** a deployment uses an MFA allowlist and the encoder MFA is included in it
- **THEN** encoding proceeds normally

### Requirement: Stream responses not encoded
Stream responses SHALL NOT be routed through the result encoder; streaming behavior SHALL remain unchanged. The result_encoder contract SHALL document this exclusion.

#### Scenario: Stream endpoint ignores encoder
- **WHEN** a `:stream` endpoint has a result_encoder configured
- **THEN** stream chunks are delivered unencoded
