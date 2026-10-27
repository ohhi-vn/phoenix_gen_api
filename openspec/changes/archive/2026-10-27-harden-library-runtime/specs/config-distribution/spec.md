# Spec Delta

## Purpose

Defines how remote configuration is authenticated, validated, versioned, stored, pulled,
and reported on, so only trusted and safe configuration can influence request routing and
no configuration path bypasses validation or silently reports success.

## ADDED Requirements

### Requirement: Every configuration write path applies the same validation

All entry points that add or update function configuration and service configuration —
including single add, batch add, update, receiver push, and puller registration — SHALL
apply the same structural and MFA safety validation before the configuration becomes
visible to request handling.

#### Scenario: Update path validates MFA
- **WHEN** a function configuration is written through the update path with an MFA that the configured safety rules forbid
- **THEN** the write is rejected and no request can resolve that configuration

#### Scenario: Push path validates like local add
- **WHEN** a configuration arrives through a push that a local add would reject
- **THEN** the push is rejected with the same class of validation error

#### Scenario: Rejected write leaves prior configuration intact
- **WHEN** a write is rejected
- **THEN** any previously registered configuration for the same key remains usable

### Requirement: Every invocable MFA is subject to safety rules

Safety validation SHALL cover every function reference a configuration can cause the
gateway to invoke: the endpoint MFA, node-resolution MFAs, before/after hooks, permission
callbacks, result encoders, and pull targets.

#### Scenario: Node resolver is forbidden
- **WHEN** a configuration supplies a node-resolution MFA using a module that the safety rules forbid
- **THEN** the configuration is rejected instead of the MFA being invoked on a later request

#### Scenario: Hook is forbidden
- **WHEN** a hook MFA uses a forbidden module
- **THEN** the configuration is rejected rather than executing the hook

#### Scenario: Explicit allowlist wins
- **WHEN** the operator explicitly allows a module in the configured allowlist
- **THEN** configurations referencing it are accepted even if it is on the built-in denylist

#### Scenario: Dangerous module set is not trivially escaped
- **WHEN** a configuration references an operating-system, filesystem, code-evaluation, process-control, or runtime-configuration module without an explicit allowlist entry
- **THEN** it is rejected

### Requirement: Configured push authentication and admin gating are enforced

When a push token is configured, pushes SHALL present it and mismatches SHALL be rejected.
When admin actions are configured, the push action SHALL consult the admin gate before
accepting a push. When neither is configured, existing unauthenticated push behaviour is
preserved.

#### Scenario: Wrong token
- **WHEN** a push presents a token different from the configured token
- **THEN** the push is rejected and recorded as an authentication failure

#### Scenario: Missing token when required
- **WHEN** a token is configured and a push presents none
- **THEN** the push is rejected

#### Scenario: Push not in admin allowlist
- **WHEN** admin actions are configured and the push action is not allowed
- **THEN** the push is rejected even if the token matches

#### Scenario: No authentication configured
- **WHEN** neither a push token nor an admin allowlist is configured
- **THEN** pushes are accepted as before, with the default posture reported in documentation

### Requirement: Configuration versions are monotonic

When downgrade rejection is enabled, the receiver SHALL reject a push whose configuration
version is older than the currently stored version for the same service and request type,
unless the caller explicitly forces the push. Version comparison SHALL only apply when
both versions are comparable.

#### Scenario: Older version pushed
- **WHEN** a push carries a version lower than the stored version and is not forced
- **THEN** the push is rejected as a downgrade and the stored configuration is unchanged

#### Scenario: Equal version pushed
- **WHEN** a push carries the same version as the stored configuration
- **THEN** the existing skip-or-refresh behaviour is preserved

#### Scenario: Non-comparable version
- **WHEN** either version cannot be compared
- **THEN** the version rule does not block the push

#### Scenario: Client selects a version
- **WHEN** version selection by clients is enabled and a client names a registered version
- **THEN** that version serves the request

#### Scenario: Client selects a version when selection is disabled
- **WHEN** version selection by clients is disabled and a client names a version
- **THEN** the current configuration serves the request and the ignored selection is recorded

### Requirement: Configuration storage is bounded

Versioned configuration and failed-configuration records SHALL be bounded by configurable
limits, and expired failed records SHALL be removed without operator action.

#### Scenario: Version flood
- **WHEN** pushes continually introduce new versions for the same service and a per-service version cap is configured
- **THEN** stored versions stay within the cap

#### Scenario: Failed records expire
- **WHEN** failed-configuration records pass their retention period
- **THEN** they are removed by a periodic sweep

#### Scenario: Recording failure without the store started
- **WHEN** a configuration is rejected while the failed-configuration store is not running
- **THEN** the rejection is still reported and the writing process does not crash

### Requirement: Push provenance can be verified

The receiver SHALL support an opt-in requirement that the pushing node is among the nodes
the pushed configuration claims to serve, and SHALL record a mismatch even when enforcement
is disabled.

#### Scenario: Source binding enabled
- **WHEN** source binding is enabled and a push arrives from a node not listed in the pushed configuration
- **THEN** the push is rejected

#### Scenario: Source binding disabled
- **WHEN** source binding is disabled and a push arrives from an unlisted node
- **THEN** the push is accepted and the mismatch is recorded

### Requirement: Pull results are reported truthfully

A pull SHALL be reported as successful only if usable configuration was stored. Partial
failure SHALL be distinguishable from complete failure, and a failed pull SHALL carry a
reason in telemetry.

#### Scenario: Pull returns nothing usable
- **WHEN** a pull yields no valid configuration for a service
- **THEN** the pull is reported as failed for that service rather than successful

#### Scenario: Partial failure
- **WHEN** some services pull successfully and others fail
- **THEN** the outcome distinguishes per-service failure and includes a failure reason

#### Scenario: Unexpected version reply
- **WHEN** a version check returns a shape that is not a scalar version
- **THEN** it is treated as a failure rather than as a version to act on

#### Scenario: Pull does not block status queries
- **WHEN** a pull is in progress
- **THEN** status and configuration queries continue to be served

### Requirement: Configuration lookup cost does not grow with version count

Resolving configuration for a request that does not name a version SHALL NOT require
scanning every stored version, and a lookup failure SHALL distinguish a missing
configuration from an unavailable cache.

#### Scenario: Many versions stored
- **WHEN** thousands of versions are stored and a request names no version
- **THEN** resolution cost is materially independent of the stored version count

#### Scenario: Cache unavailable
- **WHEN** the configuration store is unavailable
- **THEN** the request is reported as unavailable rather than as an unsupported function

#### Scenario: Genuine miss
- **WHEN** no configuration exists for the requested function
- **THEN** the request is reported as unsupported with the existing client-facing message
