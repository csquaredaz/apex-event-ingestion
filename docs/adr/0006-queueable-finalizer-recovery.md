# ADR 0006: Process in a Queueable that claims rows with a lock, and recover and continue from its Finalizer

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Chad Countryman

## Context

Stored messages (ADR 0002) have to be dispatched (ADR 0004) and their outcomes recorded: `Processed`, `Failed` with a retry time, or `Dead`. Three things make this hard on the platform:

1. A job can die on an uncatchable `LimitException` halfway through a batch. Everything it did rolls back, including any record of which messages it was working on.
2. Two jobs can run at the same time and must not process the same message twice.
3. Retries need a later trigger, but Apex has no timer short of a Queueable delay (at most 10 minutes) or a schedule.

Probes in a scratch org (2026-11-15) established:

1. **Finalizer after a `LimitException`.** A Finalizer's instance fields keep the Ids the job recorded before the limit hit. It sees the job's DML rolled back, can do DML of its own, and can enqueue one job. A second enqueue throws an uncatchable `LimitException`. The exception arrives as `System.AsyncException` with the limit message inside it.
2. **Stack depth.** Chaining from `execute` stopped at depth 5 in a Developer Edition org ("Maximum stack depth has been reached"). A job enqueued from a Finalizer starts again at depth 1. `AsyncInfo` throws outside a Queueable or Finalizer.
3. **Delay.** `AsyncOptions.MinimumQueueableDelayInMinutes = 1` ran the job about 60 seconds later.
4. **Duplicate signature.** With `QueueableDuplicateSignature`, a second enqueue throws `DuplicateMessageException` (catchable) while the first job is still Queued. Once that job is running, it or its Finalizer can enqueue under the same signature. The signature is capped at 32 bytes.
5. **Concurrent claims.** Three jobs ran the same user-mode `FOR UPDATE` query at the same moment. They took turns, and each one saw the rows the previous one had claimed as gone: 50, 30 and 0 of 80 rows, none claimed twice. A job that waits more than 10 seconds gets a catchable `QueryException` ("Record Currently Unavailable"). `ORDER BY` can't be combined with `FOR UPDATE` ("Id order is implied").
6. **Tests.** `Test.stopTest()` rethrows a job's ordinary exception, and the Finalizer still runs. A `LimitException` ends the test itself, so it can't be forced. A test context refuses, with an uncatchable `LimitException`, any job enqueued from the Finalizer of a job that succeeded; a failed job's Finalizer may enqueue. The job's DML is not rolled back before the Finalizer runs in a test. A real org has none of these limits: a successful job's Finalizer chained three generations.

## Options

### What claims a message

1. **The row lock, held for one transaction that claims, dispatches and records** (chosen). For: two jobs never take the same rows (probe 5), and a failure rolls every row back to the state it was claimed in, so no message is ever stranded mid-flight. Against: a second job waits up to 10 seconds for the lock and then gives up, so batches effectively run one at a time.
2. **A stored `Processing` status and `Locked_Until__c` written before dispatch, in the same transaction.** Against: it would always be rolled back or overwritten by the final status, so it costs a DML statement and tells a reader something the data never shows. PR 2's schema had both; this PR removes them before any release.
3. **Two jobs per batch: one claims and commits `Processing`, the next dispatches.** For: short locks, so batches can run in parallel, and an in-flight status operators can see. Against: an extra Queueable per batch, chain depth to manage, and a stall sweeper that has to reset abandoned claims. Revisit if one job at a time can't keep up.

### Who decides the next run

1. **The Finalizer, after every job** (chosen). It enqueues the next job at once when the claim filled the batch; when it scheduled a retry within 10 minutes, it delays the next job to that retry; otherwise it enqueues nothing. For: one place decides; a job enqueued from a Finalizer doesn't add stack depth (probe 2); `execute` keeps its one Queueable slot free for a handler. Against: a retry more than 10 minutes out waits for the next intake or the stall sweeper (ADR 0009).
2. **`execute` chains on success, the Finalizer only on failure.** Against: it stops at depth 5 in Developer Edition orgs, and it takes the slot a handler might need.
3. **A scheduled job only.** Against: work waits up to the schedule interval even when a full batch is waiting.

### How many jobs at once

1. **One duplicate signature on every enqueue, and a claim timeout ends a job quietly** (chosen). At most one job waits in the queue. A job whose claim times out logs a warning and stops; the job holding the lock continues the drain from its Finalizer. For: an intake that calls `MessageProcessing.enqueue()` for every batch can't flood the queue. Against: a claim refused for a permission problem also only logs a warning (`QueryException` doesn't say which). The stall sweeper alerts when due messages pile up.
2. **No signature.** Against: every intake batch would queue a job, and most would time out on the lock.

### Backoff

Exponential, `min(maxDelay, baseDelay * 2^(attempt-1))` minutes, from `Ingestion_Setting__mdt.Default` (1 minute base, 60-minute cap, 5 attempts). Every outcome counts an attempt, so `InboundMessage.getAttempt()` stays correct. There is no jitter: one queued job at a time means no retry stampede.

### Testing the Finalizer

A test can't force the `LimitException` the Finalizer exists for, and it can't take the job a successful job's Finalizer enqueues (probe 6). So the Finalizer enqueues through `IProcessorQueue`, bound by `DI_Binding.Processor_Queue`, and tests substitute a mock. The Finalizer's unit tests call it directly with a fake `FinalizerContext`. An integration test makes a mocked dispatcher throw past the guard and checks that every claimed message ends `Failed` with a backoff. `Test.isRunningTest()` branches were rejected: production code doesn't branch on tests (apex-testing rule 10).

## Decision

`MessageProcessorJob` attaches `MessageProcessorFinalizer`, claims up to the batch size with `IInboundMessagesSelector.selectClaimable` (user mode, `FOR UPDATE`, Id order), dispatches through `IMessageDispatcher`, and records the results through `IMessageLifecycle`, all in one transaction:

- `SUCCESS` → `Processed`, with `Processed_At__c`; the retry time and error are cleared.
- `RETRYABLE` → `Failed` with the next attempt time, or `Dead` once attempts run out.
- `FATAL` → `Dead`.
- `Last_Error__c` is cut to its 32,768 characters, because dispatch joins errors without truncating (ADR 0004).
- Any message going `Dead` raises one WARNING through `IAlertSink`.

If the job fails past the handlers' guard, the Finalizer counts a retryable attempt for each claimed message that isn't already terminal, and raises a CRITICAL alert. Either way, it then decides the next run.

## Consequences

- Limits per job: 1 SOQL to claim, 1 to load payloads, the handlers' own budget, and 1 DML statement for statuses; recovery adds 1 SOQL and 1 DML in the Finalizer. Bulk-tested at 200.
- The lifecycle is `Received → Processed`, or `Failed` and then `Dead`. There is no stored in-flight status, so ADR 0009's sweeper only has to find due messages with no job, not reset abandoned locks.
- **Known limit:** if recovery itself fails (for example, `UNABLE_TO_LOCK_ROW` because another job holds the rows), the messages keep their previous state without an attempt counted. A message that always breaks the job then never reaches `Dead`. The Finalizer logs and alerts, and doesn't continue, so it doesn't loop at once; the stall sweeper alerts on messages that stay due.
- Alerts name Ids and counts only. Exception text can quote payload data, so it goes to `Last_Error__c` and the log.
- `IInboundMessagesSelector` gained `selectClaimable`. apex-core-lib's `SObjectSelector.query` always appends `ORDER BY`, so the selector builds the locking statement itself; a `FOR UPDATE` variant could move into apex-core-lib in a minor version.
- **Ownership:** the job claims and updates in user mode, and `Inbound_Message__c` is Private. `Event_Ingestion_Processor` has View All but not Modify All, so the job can claim a message another user owns but can't update it (`INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`, proven 2026-11-15). The batch then rolls back, the recovery fails the same way, and the Finalizer alerts. Storing and processing must run as the same user. **Settled by ADR 0007 (2026-11-16):** messages arrive through `Inbound_Message_Event__e` and are stored and processed by the Automated Process user, which a probe showed can update every message, including rows other users own.
- Rollback posture: deactivate a route to stop its handler (ADR 0004), or abort the queued `MessageProcessorJob` in Setup → Apex Jobs; nothing else enqueues it until the next intake.
