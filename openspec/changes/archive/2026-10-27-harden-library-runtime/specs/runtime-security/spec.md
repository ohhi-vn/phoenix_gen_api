# Spec Delta

## Purpose

Defines the security primitives the runtime relies on — administrator gating, secret
comparison, MFA safety rules, trusted identity, atom safety, and internal table exposure
— so that each control is complete, correctly implemented, and impossible to bypass by
choosing a different code path.

## ADDED Requirements

### Requirement: Privileged operations consult the admin gate

When admin actions are configured, every operation that changes runtime behaviour or
exposes data — configuration push, rate-limit administration, error-detail changes,
tracing control, and any equivalent mutation — SHALL consult the admin gate, including
when invoked directly rather than through the public convenience function.

#### Scenario: Gate configured and action allowed
- **WHEN** an action is listed in the configured admin actions and an operator performs it
- **THEN** the operation proceeds

#### Scenario: Gate configured and action denied
- **WHEN** an action is not listed in the configured admin actions
- **THEN** the operation is refused and the refusal is recorded

#### Scenario: Gate not configured
- **WHEN** no admin actions are configured
- **THEN** existing behaviour is preserved for every operation

#### Scenario: Direct invocation
- **WHEN** a privileged operation is invoked directly on its owning process rather than through the public function
- **THEN** the same gate decision applies

### Requirement: Secret comparison does not leak secret length

Push-token comparison SHALL execute a fixed amount of work independent of the length of
the supplied or configured secret, and SHALL accept exactly the same inputs as before.

#### Scenario: Candidate shorter than the secret
- **WHEN** a candidate token shorter than the configured token is compared
- **THEN** comparison work does not grow with the configured token's length

#### Scenario: Candidate longer than the secret
- **WHEN** a candidate token longer than the configured token is compared
- **THEN** comparison work is the same as for any other candidate and the token is rejected

#### Scenario: Correct token
- **WHEN** the correct token is presented
- **THEN** the push is accepted

### Requirement: MFA safety rules are exact and complete

Allowlist matching SHALL be exact for modules and for module/function pairs, with no
prefix, substring, or partial-match acceptance. The built-in denylist SHALL cover
operating-system, filesystem, code-evaluation, process-control, and runtime-configuration
surfaces, and SHALL be documented as the default posture.

#### Scenario: Prefix of an allowed module
- **WHEN** a configuration references a module whose name extends an allowed module's name
- **THEN** it is not treated as allowed

#### Scenario: Allowed module, unlisted function
- **WHEN** the allowlist grants specific functions of a module
- **THEN** a different function of that module is rejected

#### Scenario: Denylisted module
- **WHEN** a configuration references a module on the built-in denylist and the allowlist does not grant it
- **THEN** the configuration is rejected

### Requirement: Identity used for authorization comes from the authenticated context

Authorization that depends on user identity or roles SHALL be able to require that both
are established by the transport's authenticated context rather than by the request
payload. When this enforcement is enabled, payload-supplied roles SHALL be ignored and an
unverified payload user identifier SHALL be treated as absent.

#### Scenario: Enforcement enabled, payload roles
- **WHEN** role enforcement is enabled and a client supplies roles in the payload while the authenticated context supplies none
- **THEN** the request is authorized with no roles

#### Scenario: Enforcement enabled, unverified user id
- **WHEN** user-identifier enforcement is enabled and no verified identifier is available
- **THEN** the payload identifier fails authenticated-user checks

#### Scenario: Enforcement disabled
- **WHEN** enforcement is disabled
- **THEN** existing behaviour is preserved and the residual risk is documented

### Requirement: Configuration and client input never create atoms

No request field, configuration value, or administrative input SHALL cause creation of a
new atom; lookups that need an atom SHALL resolve only atoms that already exist and SHALL
treat unknown names as unmatched.

#### Scenario: Unknown sticky key field
- **WHEN** a configuration selects a sticky-node key that is not a known request field
- **THEN** the lookup treats it as unmatched without creating an atom

#### Scenario: Attacker-chosen key strings
- **WHEN** many distinct key strings arrive through configuration
- **THEN** the atom table does not grow

### Requirement: Internal state tables are protected when hardening is enabled

The system SHALL support restricting writes to its named ETS tables to the processes that
own them, so unrelated local processes cannot rewrite configuration, relay membership,
rate-limit state, or failed-configuration records directly.

#### Scenario: Protection enabled
- **WHEN** table protection is enabled and an unrelated process attempts to write internal state
- **THEN** the write is refused

#### Scenario: Protection disabled
- **WHEN** table protection is disabled
- **THEN** existing callers continue to read and write as before

#### Scenario: Module APIs keep working
- **WHEN** protection is enabled and callers use the documented module APIs
- **THEN** reads and writes behave as before

### Requirement: Privileged tracing is gated and capture is controllable

Enabling tracing or changing its scope SHALL consult the admin gate when admin actions are
configured, and capture of full request arguments SHALL be controllable so payloads are
not necessarily written to disk.

#### Scenario: Tracing enabled while gated
- **WHEN** admin actions are configured and tracing is enabled by an unauthorized caller
- **THEN** the operation is refused

#### Scenario: Argument capture disabled
- **WHEN** argument capture is disabled
- **THEN** trace records omit request argument values

#### Scenario: Tracing disabled
- **WHEN** tracing is disabled
- **THEN** no trace artifacts are produced and the global logging configuration is unchanged
