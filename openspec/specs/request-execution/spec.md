# request-execution Specification

## Purpose

Defines how a request is resolved, executed, retried, bounded, and converted into a
response, so that every failure produces one honest, classifiable outcome instead of a
crash, a hang, or a misleading message.

## Requirements

### Requirement: Every request failure maps to one classification

Each failed request SHALL be classified as one of: invalid request, permission denied,
rate limited, unavailable, timeout, or internal. The classification SHALL be recorded in
telemetry and logs, while the public response struct and its existing message text for
each failure class remain unchanged.

#### Scenario: Endpoint raises
- **WHEN** a local endpoint raises during execution
- **THEN** telemetry records the internal class with the original exception and stacktrace, and the caller receives an error response rather than an exit

#### Scenario: Target unavailable
- **WHEN** no target node can serve a remote request
- **THEN** telemetry records the unavailable class, distinguishing it from a timeout and from a client error

#### Scenario: Classification does not change the response shape
- **WHEN** any classified failure is returned to a WebSocket client
- **THEN** the response has the same fields and message text as before this change

### Requirement: Endpoint crashes are isolated from the caller

Execution of a configured MFA, and any timeout-guarded execution, SHALL run without
linking the caller to the executing process, so a raise, throw, or exit in the endpoint
terminates only that execution and is reported as an error outcome.

#### Scenario: Local endpoint raises
- **WHEN** a local endpoint raises an exception
- **THEN** the channel or caller process stays alive and receives an error response naming the failure

#### Scenario: Endpoint exits abnormally
- **WHEN** an endpoint calls `exit/1` with a non-normal reason
- **THEN** the execution is reported as failed and the caller is not killed

#### Scenario: Timeout does not double-report
- **WHEN** an execution completes at the same moment its timeout expires
- **THEN** exactly one outcome is returned and it reflects whether the work completed

### Requirement: Execution timeouts are hard bounds

A configured timeout SHALL bound the wall-clock time spent on the execution, including
any wait for shutdown of the executing process, and SHALL produce the timeout outcome
once exceeded.

#### Scenario: Endpoint ignores shutdown
- **WHEN** an endpoint exceeds its timeout and does not respond to graceful shutdown
- **THEN** it is terminated forcibly and the timeout outcome is returned within a bounded margin

#### Scenario: Remote call timeout
- **WHEN** a remote RPC exceeds the configured timeout
- **THEN** the attempt is classified as a timeout and the next retry or fallback proceeds

#### Scenario: Unsupported timeout value
- **WHEN** a configuration requests an execution timeout that cannot be honoured as specified
- **THEN** the effective timeout is reported in telemetry and a warning is emitted, rather than silently substituting a different bound

### Requirement: Retry exhaustion preserves the last real failure

When all retry attempts fail, the system SHALL retain the last underlying failure reason
for telemetry and SHALL return the single documented exhaustion message. Local and remote
retry paths SHALL report exhaustion consistently.

#### Scenario: Remote retries exhausted
- **WHEN** every remote retry attempt fails
- **THEN** telemetry carries the final attempt's reason and attempt count, and the client receives the documented exhaustion message

#### Scenario: Local retries exhausted
- **WHEN** every local retry attempt fails
- **THEN** the same exhaustion outcome is produced as for the remote path

#### Scenario: Node resolution fails before retrying
- **WHEN** the target node list cannot be resolved
- **THEN** retrying stops immediately, the resolution failure is reported, and no empty-list retry loop runs

### Requirement: Streams always end with a terminal outcome

Every stream SHALL deliver exactly one terminal frame to its receiver — successful
completion, error, or timeout — and SHALL emit a stop or exception event. A stream whose
producer dies abnormally SHALL surface an error frame instead of leaving the client
waiting.

#### Scenario: Stream completes
- **WHEN** a producer finishes without error
- **THEN** the receiver gets a terminal frame with `has_more: false` and a stop event is emitted

#### Scenario: Stream timeout
- **WHEN** a stream exceeds its configured timeout
- **THEN** the producer is stopped, the receiver gets an error frame, and a timeout event is emitted

#### Scenario: Producer crashes
- **WHEN** a stream producer exits for a reason other than normal shutdown
- **THEN** the receiver gets an error frame and an exception event includes the exit reason

### Requirement: Hook results and hook timeouts are honoured

A configured `after_execute` hook's returned result SHALL be the result of the request,
and a configured hook timeout SHALL bound hook execution instead of a fixed internal
value. Hook failures SHALL remain non-fatal but SHALL be distinguishable from a hook
that returned an unchanged result.

#### Scenario: After hook mutates the response
- **WHEN** an after-execute hook returns a modified response
- **THEN** the caller receives the modified response

#### Scenario: Hook timeout configured
- **WHEN** a function configuration sets a hook timeout shorter than the default
- **THEN** a hook exceeding that timeout is abandoned at the configured bound

#### Scenario: Hook returns unchanged result
- **WHEN** a hook returns the same response it received without failing
- **THEN** it is not reported as a hook failure

### Requirement: Request handling work is independent of unrelated state size

Per-request work SHALL NOT grow with the number of unrelated registered configurations,
configured rate limits, or argument elements beyond the element's own validation, and
SHALL NOT build tracing, inspection, or node-resolution artifacts when the corresponding
feature is disabled.

#### Scenario: Many versions registered
- **WHEN** a request resolves a function without naming a version and thousands of versions are registered
- **THEN** resolution cost is materially independent of the total registered version count

#### Scenario: Tracing disabled
- **WHEN** tracing is globally disabled
- **THEN** no trace payload, MFA string, or timestamp is built for the request

#### Scenario: Large argument list
- **WHEN** a request supplies a large list of primitive arguments
- **THEN** validation performs a bounded number of configuration reads for the whole list rather than one per element

### Requirement: Argument type mismatches are validation errors

Argument validation SHALL reject a value whose container type does not match the
declared type by raising the library's validation error, not by raising a raw runtime
error such as `ArgumentError` or `BadMapError`.

#### Scenario: Scalar supplied for a string
- **WHEN** an integer is supplied for a `:string` argument
- **THEN** validation fails with the library's validation error and the request is reported as an invalid request

#### Scenario: Scalar supplied for a list
- **WHEN** a string is supplied for a list argument
- **THEN** validation fails with the library's validation error instead of a length or size failure

### Requirement: Payload size limits remain enforced

The inbound payload size limit SHALL remain enforced before decoding, and exceeding it
SHALL be reported as an invalid request.

#### Scenario: Oversized payload
- **WHEN** a request payload exceeds the configured maximum size
- **THEN** decoding is refused and the request is classified as invalid
