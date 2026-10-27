# Spec Delta

## Purpose

Defines how asynchronous and streaming work is queued, dispatched, isolated, and
accounted for, so pool capacity is never exceeded, a crash never silently loses accepted
work, and pool status reflects reality.

## ADDED Requirements

### Requirement: Each task produces exactly one completion signal

The pool SHALL treat a task as busy until exactly one completion signal is received.
Repeated completion notifications for the same execution SHALL NOT cause additional
queued tasks to be dispatched to a worker that is still busy.

#### Scenario: Successful asynchronous task
- **WHEN** a task completes successfully
- **THEN** the worker becomes idle once and at most one queued task is dispatched to it

#### Scenario: Failing task
- **WHEN** a task raises, exits, or times out
- **THEN** exactly one completion is processed and the failure is recorded once

#### Scenario: Duplicate completion arrives
- **WHEN** a completion signal arrives for a worker that the pool already considers idle
- **THEN** the signal is ignored without dispatching another task

### Requirement: Pool concurrency is a hard limit

The number of tasks executing concurrently in a pool SHALL NOT exceed the pool's
configured size, regardless of completion-signal ordering or worker state.

#### Scenario: Burst of queued work
- **WHEN** more tasks are queued than the pool has workers
- **THEN** no worker runs more than one task at a time

#### Scenario: Mixed success and failure completions
- **WHEN** tasks complete with a mix of successes and failures under load
- **THEN** the number of in-flight tasks never exceeds the configured pool size

### Requirement: A worker crash does not discard accepted work

A worker or task crash SHALL NOT terminate the pool or its queue, and SHALL NOT cause
already-accepted tasks to be silently abandoned. The pool SHALL replace failed workers
and continue draining its queue.

#### Scenario: Worker process dies
- **WHEN** a worker process is killed while the pool holds queued tasks
- **THEN** the pool survives, replaces the worker, and continues processing the queue

#### Scenario: Replacement worker fails to start
- **WHEN** respawning a worker fails
- **THEN** the pool records the failure, emits a restart event, and retries rather than crashing

#### Scenario: Dead worker completion arrives late
- **WHEN** a completion signal arrives for a pid that is no longer a pool member
- **THEN** the pid is not re-added to the idle set and is never dispatched new work

### Requirement: Rejected tasks are reported to the caller

A task that the pool cannot accept or cannot start SHALL be reported to the caller as a
rejection with a reason. The pool SHALL NOT return success for a task that was not
accepted, queued, or executed.

#### Scenario: Queue full
- **WHEN** the queue has reached its configured maximum size
- **THEN** the caller receives a queue-full rejection

#### Scenario: Circuit breaker open
- **WHEN** a worker or the pool has an open circuit breaker
- **THEN** the caller receives an explicit rejection and the task is not reported as accepted

#### Scenario: Pool not running
- **WHEN** async or stream work is submitted while no pool is running
- **THEN** the caller receives an unavailable rejection instead of an exit or a case-clause crash

### Requirement: Circuit-breaker state pauses dispatch

While a worker's circuit is open, that worker SHALL be withheld from dispatch until the
cooldown expires. Work SHALL NOT be handed to a circuit-open worker and then discarded.

#### Scenario: Worker circuit opens
- **WHEN** a worker trips its circuit breaker
- **THEN** it stops receiving queued tasks until the cooldown elapses

#### Scenario: Cooldown expires
- **WHEN** the cooldown elapses and the worker is healthy
- **THEN** the worker returns to normal dispatch

### Requirement: Pool status reports real values

Pool status SHALL report counts and failure state that reflect actual pool activity:
membership counts SHALL exclude dead workers, and failure counters SHALL increment when
tasks fail.

#### Scenario: Worker died
- **WHEN** a worker dies and has not yet been replaced
- **THEN** status does not count it as an available worker

#### Scenario: Task failures occurred
- **WHEN** tasks have failed since the pool started
- **THEN** status reports a non-zero failure count consistent with the recorded failures

### Requirement: Task resources are released on completion

Per-task timers and monitors SHALL be released when the task finishes, so long-running
services do not accumulate stale timers or unmatched messages proportional to throughput.

#### Scenario: Fast task with long timeout
- **WHEN** a task completes well before its configured timeout
- **THEN** its timeout timer is cancelled and no stale timeout message is later processed

#### Scenario: Timeout fires
- **WHEN** a task reaches its timeout
- **THEN** the timer is consumed, the task is terminated, and the completion is recorded once

### Requirement: Async and stream work use their own capacity

Streaming work SHALL be dispatched to the pool reserved for streams when that pool is
running, and SHALL NOT consume the general async pool's capacity indefinitely.

#### Scenario: Stream submitted
- **WHEN** a stream request is accepted and a stream pool is configured
- **THEN** the stream occupies stream-pool capacity rather than async-pool capacity

#### Scenario: Streams saturate
- **WHEN** many streams are active concurrently
- **THEN** ordinary async requests are not starved by them
