# Spec Delta

## Purpose

Defines what every PhoenixGenApi log line must contain so operators can correlate a
client request, a config push/pull, and a remote RPC across gateway and service nodes,
while keeping secrets and bulk payloads out of the log stream.

## ADDED Requirements

### Requirement: Every log line carries a module and event identity

Each library log line SHALL begin with a stable `[ModuleName]` prefix and SHALL include a
machine-searchable `event=<snake_case>` token describing what happened, so a line can be
attributed and filtered without parsing free-form prose.

#### Scenario: Config validation failure is attributable
- **WHEN** a pushed configuration fails validation
- **THEN** the emitted error line starts with the receiver's `[ModuleName]` prefix and contains an `event=` token identifying the validation failure

#### Scenario: Existing wording remains greppable
- **WHEN** an operator searches for a message that existed before this change
- **THEN** the existing key phrase is still present in the emitted line, with the new context fields appended

### Requirement: Request-scoped context accompanies every request log line

Every log line emitted while handling a request SHALL include the request's `request_id`,
`request_type`, `service`, and `user_id` when those values are known, and SHALL mark
unknown values explicitly rather than omitting the keys.

#### Scenario: Unsupported function lookup
- **WHEN** a request names a function that is not registered
- **THEN** the warning line includes the requested `request_type`, the resolved `service` (or an explicit unknown marker), the `request_id`, and the `user_id`

#### Scenario: Argument validation failure deep in conversion
- **WHEN** argument conversion fails inside a nested map or list
- **THEN** the error line includes the outer request's `request_type` and `request_id`, not only the offending key or value

#### Scenario: Worker pool rejection
- **WHEN** the async or stream pool rejects a task because the queue is full or the circuit breaker is open
- **THEN** the warning line identifies the affected `request_id`, `request_type`, `service`, and originating `node`

### Requirement: Node context names the relevant node

A log line that concerns remote execution, node selection, config push, or config pull
SHALL name the node the line refers to: the target node for RPC and selection outcomes,
the pushing node for received pushes, and the source node for pulled configuration. When
no single node is involved, the current node SHALL be named.

#### Scenario: Remote RPC fallback
- **WHEN** an RPC attempt on a node times out and the executor falls back to another node
- **THEN** the warning line names the failed node and the request identity, and distinguishes the fallback outcome from the final outcome

#### Scenario: Received config push
- **WHEN** a node pushes configuration to the receiver
- **THEN** every accept, skip, and reject line for that push names the pushing node and the pushed `service`

#### Scenario: Node selection failure
- **WHEN** no node can be selected for a request
- **THEN** the error line names the request identity and the selection failure reason, and states that no target node was available

### Requirement: Config lifecycle lines identify service, version, and affected request types

Log lines for config reception, pulling, pushing, insertion, and failure recording SHALL
identify the `service`, the relevant `version` (pushed version, stored version, or pull
version), and the affected `request_type` values or an explicit count of them.

#### Scenario: Push validation fails without per-item detail
- **WHEN** a push is rejected because the pushed document itself is invalid
- **THEN** the error line includes the pushed `service`, the pushed `config_version`, the pushing `node`, the field-level validation errors, and the count or names of the `request_type` entries carried by the push

#### Scenario: Pull inserts a batch
- **WHEN** configuration pulled from a node is inserted
- **THEN** the line includes the `service`, the source `node`, the inserted count, and the request types or count of inserted entries

#### Scenario: Partial push
- **WHEN** some function entries in a push are valid and others are not
- **THEN** the warning line reports the `service`, the number of accepted and rejected entries, and the `request_type` of each rejected entry

### Requirement: Context survives process handoffs

When request handling continues in another process — async execution, stream
execution, or a worker pool task — the request-scoped log context SHALL be installed in
that process before user code or library code logs, and SHALL be restored or discarded
after the task ends so it does not leak into later work on a reused process.

#### Scenario: Async task logs
- **WHEN** an async request executes inside a worker pool process
- **THEN** any log line emitted by that task carries the originating `request_id`, `request_type`, `service`, and `user_id`

#### Scenario: Stream process logs
- **WHEN** a stream request runs in its own process
- **THEN** its log lines carry the originating request context and the stream process identity

#### Scenario: Reused worker does not inherit stale context
- **WHEN** a worker finishes one request and starts another
- **THEN** the second request's log lines do not contain the first request's identity

### Requirement: Secrets are never logged and bulk payloads require opt-in

Log lines SHALL NOT contain push tokens, credentials, or other secret values, and SHALL
NOT contain full request payloads, argument values, or function results unless the
operator explicitly enables verbose payload logging.

#### Scenario: Push token rejection
- **WHEN** a push is rejected for an invalid token
- **THEN** the warning line identifies the `service` and pushing `node` and records only that the token was rejected, never the token value

#### Scenario: Debug logging of incoming request
- **WHEN** debug logging is enabled without verbose payload opt-in
- **THEN** the incoming-request line records the request identity and payload size or field names, not the payload contents

#### Scenario: Verbose payload logging enabled
- **WHEN** the operator explicitly enables verbose payload logging
- **THEN** payload, argument, and result dumps are emitted at debug level only

### Requirement: Log levels reflect operator actionability

Log levels SHALL be chosen by operator actionability: configuration, dispatch, and
security failures that need attention SHALL be `warning` or `error`; successful
per-request lifecycle steps, retries, and cleanup SHALL be `debug` or `info` so they can
be suppressed without losing actionable failures.

#### Scenario: Successful per-request step
- **WHEN** a request completes a routine internal step such as argument conversion or a retry attempt
- **THEN** the line is emitted at `debug` or `info`, not `error`

#### Scenario: Client input rejection
- **WHEN** a caller sends arguments that violate the declared schema
- **THEN** the line is emitted at `warning` or `debug` and includes the request identity, reflecting that the server is healthy

#### Scenario: Config rejected by the server
- **WHEN** a pushed or pulled configuration is rejected because it is invalid or unsafe
- **THEN** the line is emitted at `error` and includes the service, version, and node context

### Requirement: Context vocabulary is stable, documented, and formatter-independent

The library SHALL use one documented set of context keys across all modules, and a line's
inline context SHALL remain sufficient to trace the event when the log formatter does not
render Logger metadata.

#### Scenario: Metadata not rendered by formatter
- **WHEN** an application uses the default formatter that ignores Logger metadata
- **THEN** the log line still names the module, event, request identity, service, and node inline

#### Scenario: Metadata rendered by formatter
- **WHEN** an application configures a formatter that renders Logger metadata
- **THEN** the request-scoped metadata appears on the line using the documented key names without duplicating conflicting values

#### Scenario: New module follows the contract
- **WHEN** a new module in the library emits a log line
- **THEN** it uses the documented context keys and does not introduce a private synonym for an existing key
