# relay-messaging Specification

## Purpose

Defines how relay groups are created, joined, authorized, and messaged, so membership is
not self-asserted, fan-out is bounded, delivery is reported honestly, and the relay
server cannot lose all group state because of one malformed operation.

## Requirements

### Requirement: Relay management actions verify the acting user

Group creation, deletion, join approval, and membership changes SHALL support verifying
that the acting user is the authenticated caller, rather than trusting an actor identifier
supplied by the caller.

#### Scenario: Actor matches caller
- **WHEN** a caller requests a management action for itself and verification is enabled
- **THEN** the action proceeds if the caller holds the required role

#### Scenario: Actor asserted for another user
- **WHEN** a caller supplies another user's identifier as the actor and verification is enabled
- **THEN** the action is refused

#### Scenario: Verification disabled
- **WHEN** actor verification is disabled
- **THEN** existing callers continue to work and the residual risk is documented

### Requirement: Local groups only admit local members

When local-only membership enforcement is enabled and a relay group is local to the node,
joining SHALL reject process identifiers that belong to another node, and SHALL reject
membership changes that do not originate from an authorized actor.

#### Scenario: Remote pid joins a local group
- **WHEN** a membership request supplies a process identifier owned by another node for a local group
- **THEN** the join is refused

#### Scenario: Local pid joins
- **WHEN** a local process joins a local group with a valid actor
- **THEN** membership is recorded and the member receives subsequent messages

### Requirement: Relay fan-out is bounded

Group membership and message delivery SHALL be bounded by configurable limits on group
size, message size, and recipient count, and exceeding a limit SHALL be reported as a
rejection rather than silently truncated.

#### Scenario: Group size limit
- **WHEN** a join would exceed the configured group size limit
- **THEN** the join is refused with a size-limit reason

#### Scenario: Oversized message
- **WHEN** a relay message exceeds the configured message size limit
- **THEN** the message is refused and no member receives a partial message

#### Scenario: Recipient cap
- **WHEN** a message would fan out to more recipients than the configured cap
- **THEN** delivery is refused rather than partially delivered

#### Scenario: Limits unset
- **WHEN** no relay limits are configured
- **THEN** existing unlimited behaviour is preserved

### Requirement: Relay server survives malformed operations with state intact

An unexpected input, invalid group state transition, or raising operation SHALL be
reported to the caller as an error, and SHALL NOT terminate the relay server or discard
existing groups and memberships.

#### Scenario: Invalid group transition
- **WHEN** an operation requests a transition the group's current state does not permit
- **THEN** the caller receives an error and other groups remain intact

#### Scenario: Malformed membership input
- **WHEN** a membership request carries input the relay cannot process
- **THEN** the caller receives an error and the relay continues serving other operations

### Requirement: Relay monitors are released

A relay monitor SHALL be removed when the monitored process leaves, when the group is
deleted, and when a membership is replaced, so long-lived gateways do not accumulate
monitors.

#### Scenario: Member leaves
- **WHEN** a member leaves a group
- **THEN** its monitor is removed

#### Scenario: Group deleted
- **WHEN** a group is deleted
- **THEN** monitors for every member of that group are removed

#### Scenario: Member rejoins
- **WHEN** a member joins a group it already belongs to with a new process identifier
- **THEN** the previous monitor is removed and only the new one remains

### Requirement: Delivery outcome is reported distinctly from recipient count

The relay SHALL report how many members the message targeted separately from how many
were actually delivered, and SHALL emit a lifecycle event for accepted and delivered
messages.

#### Scenario: Some recipients gone
- **WHEN** a message targets five members and two process identifiers are no longer alive
- **THEN** the result distinguishes five targeted recipients from three deliveries

#### Scenario: Message accepted
- **WHEN** a relay message is accepted for fan-out
- **THEN** a relay lifecycle event records the group and the targeted count

### Requirement: One stalled group does not block other relay operations

A slow or large fan-out SHALL NOT prevent unrelated group operations, joins, or messages
from being served.

#### Scenario: Large fan-out
- **WHEN** a message fans out to a group with many members
- **THEN** other groups can still be created, joined, and messaged concurrently

#### Scenario: Relay unavailable
- **WHEN** the relay process is not running
- **THEN** callers receive an unavailable error rather than an exit
