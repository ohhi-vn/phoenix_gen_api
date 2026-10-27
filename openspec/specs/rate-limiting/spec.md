# rate-limiting Specification

## Purpose

Defines how rate limits are keyed, counted, bounded, and administered, so limits are
accurate under concurrency, cost nothing when unused, fail according to their configured
policy, and cannot be silently disabled or silently skipped.

## Requirements

### Requirement: No configured limits means no limiter cost

When no global or per-API limits are configured, or the limiter is disabled, a request
SHALL NOT require a round-trip to a limiter process and SHALL NOT copy the request
payload to that process.

#### Scenario: Limiter enabled with no limits
- **WHEN** the limiter is enabled but no limits are configured
- **THEN** requests are allowed without a limiter process round-trip

#### Scenario: Limits configured at runtime
- **WHEN** limits are added or removed at runtime
- **THEN** subsequent requests observe the new configuration without requiring a restart

#### Scenario: Limiter disabled
- **WHEN** the limiter is disabled by configuration
- **THEN** requests are allowed without contacting a limiter process

### Requirement: Configured fail mode applies to every failure kind

The configured fail-open or fail-closed policy SHALL apply to timeouts, process exits,
missing limiter processes, and exceptions alike, and the applied outcome SHALL be recorded
with the failure reason.

#### Scenario: Limiter process times out
- **WHEN** a limiter call exceeds its timeout
- **THEN** the request is allowed or denied according to the configured fail mode, and the timeout is recorded

#### Scenario: Limiter process is not running
- **WHEN** the limiter process is unavailable
- **THEN** the configured fail mode is applied instead of the request crashing

#### Scenario: Limiter raises
- **WHEN** the limiter raises while checking a request
- **THEN** the configured fail mode is applied and the exception is recorded

### Requirement: Rate-limit key resolution is explicit

A limit SHALL only key on documented, resolvable request attributes. When a configured
key source cannot be resolved for a request, the system SHALL record that once at
configuration time and again when it prevents an enabled limit from being evaluated,
instead of silently skipping the limit.

#### Scenario: IP address source unavailable
- **WHEN** a limit is configured to key on a request attribute the request never carries
- **THEN** configuration loading reports the unsupported key source and enforcement does not appear active while silently skipping

#### Scenario: Custom argument key missing
- **WHEN** a custom argument key is configured and a request omits it
- **THEN** the limit evaluation outcome is recorded as skipped for a missing key rather than counted under an empty key

### Requirement: Limiter memory is bounded

Limiter state SHALL be bounded per key by the configured maximum request count, and SHALL
allow an operator to bound the total number of distinct keys and the size of key material.
Exceeding a key bound SHALL degrade to a coarse bucket rather than growing without limit.

#### Scenario: Sliding window at maximum
- **WHEN** a key has reached its configured maximum request count within the window
- **THEN** stored state for that key does not grow beyond that count

#### Scenario: Key cardinality flood
- **WHEN** clients rotate a client-controlled key value on every request and a key cap is configured
- **THEN** total limiter keys stay within the cap

#### Scenario: Oversized key material
- **WHEN** a limit keys on a very large client-supplied string and key-size bounding is configured
- **THEN** the stored key is bounded in size without changing the limit's decision for identical inputs

### Requirement: Concurrent checks are accounted consistently

Concurrent checks for the same key SHALL be counted without lost updates, regardless of
the instance routing strategy, and a request SHALL NOT be admitted beyond the configured
limit because of a lost update.

#### Scenario: Concurrent burst on one key
- **WHEN** concurrent requests for the same key are checked against the same window
- **THEN** the number of admitted requests does not exceed the configured limit

#### Scenario: Random routing
- **WHEN** the routing strategy distributes requests across limiter instances
- **THEN** concurrent checks for the same key remain accurately counted

#### Scenario: Mixed check entry points
- **WHEN** the same key is checked through both the request-based and direct check entry points
- **THEN** both paths observe and update the same accounting

### Requirement: Runtime limit administration is gated consistently

When admin actions are configured, every operation that changes limiter configuration,
resets counters, or clears state SHALL consult the admin gate, including operations
invoked directly against a limiter instance.

#### Scenario: Admin actions configured
- **WHEN** admin actions are configured and a caller without permission attempts to replace, add, or remove limits or clear state
- **THEN** the operation is refused and the refusal is reported

#### Scenario: Admin actions not configured
- **WHEN** no admin actions are configured
- **THEN** existing administrative callers continue to work unchanged

### Requirement: Cleanup honours configuration and does not stall checks

Limiter cleanup SHALL use the configured cleanup interval and the runtime limit
configuration, and SHALL NOT block the limiter's request-checking path while sweeping.

#### Scenario: Custom cleanup interval
- **WHEN** an operator configures a cleanup interval
- **THEN** sweeps occur at that interval rather than the built-in default

#### Scenario: Sweep in progress
- **WHEN** a cleanup sweep is running
- **THEN** rate-limit checks continue to be served

#### Scenario: Window changed at runtime
- **WHEN** a longer window is installed at runtime
- **THEN** cleanup retains timestamps that are still inside the effective window

### Requirement: Check cost does not grow with unrelated limits

The cost of checking a request against configured per-API limits SHALL depend on the
limits that apply to that request, not on the total number of configured limits.

#### Scenario: Many endpoints configured
- **WHEN** hundreds of per-API limits are configured and a request matches one of them
- **THEN** the check resolves the applicable limit without scanning every configured limit
