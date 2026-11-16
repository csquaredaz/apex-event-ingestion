# ADR 0007: Take messages in through a high-volume Platform Event, stored by the Automated Process user

- **Status:** Accepted
- **Date:** 2026-11-16
- **Deciders:** Chad Countryman

## Context

Producers need one way to hand messages to the package that works from Apex, Flow and the APIs, and that decouples them from the store (ADR 0002) and from processing (ADR 0006). Whatever receives the messages must store each one once, never lose one to a transient failure, and start processing.

Probes in a Developer Edition scratch org (2026-11-16) established:

1. **The subscriber's user.** A Platform Event trigger runs as the Automated Process user, and so does the Queueable it enqueues, and that job's Finalizer.
2. **The Automated Process user's access.** With **no** permission set assigned, that user passed the store's `isCreateable()` checks, inserted `Inbound_Message__c` rows in user mode, and its processor job claimed them with a user-mode `FOR UPDATE` and updated them. It also updated a row **another user owned**, with OWD Private. Its profile is hidden from SOQL. This differs from External Credential principal access, which this user still needs a permission set for (apex-platform-logging).
3. **Retries.** Throwing `EventBus.RetryableException` rolls back the run and redelivers it, with `EventBus.TriggerContext.retries` counting up. `Test.getEventBus().deliver()` does the same in a test.
4. **Resume checkpoints.** A run that takes some events, calls `setResumeCheckpoint` with the last one's `ReplayId` and returns normally gets the rest in new runs. Five events at two per run arrived as runs of 5, 3 and 1 and were stored once each. A test delivery behaves the same way.
5. **Naming.** A Platform Event can't share a custom object's base name, so `Inbound_Message__e` is rejected next to `Inbound_Message__c` ("That object name is already in use"). The event is `Inbound_Message_Event__e`.

Platform limits that shape the design: a Platform Event trigger receives up to 2,000 events per run; an async transaction has a 12 MB heap and a payload field holds 131,072 characters; a trigger is retried at most 9 times and is then suspended, keeping its events for 72 hours until it is resumed in Setup.

## Options

### How messages arrive

1. **A high-volume Platform Event, `Inbound_Message_Event__e`, with an `after insert` trigger** (chosen). For: one contract for Apex, Flow, REST, Pub/Sub API and MuleSoft; the producer's transaction never waits for or fails on the store; the event bus retries for free. Against: delivery is asynchronous, and a producer gets no per-message `AppendResult`, only the publish result.
2. **Producers call `IMessageStore.append` directly.** For: synchronous results. Against: producers need `Event_Ingestion_Processor` and run the store inside their own transaction; it remains available for Apex producers that want results.
3. **An Apex REST endpoint.** For: synchronous results for external callers. Against: only for external callers, and it needs its own auth, versioning and retry story.

### Who stores and processes the messages

1. **The Automated Process user, with no permission set** (chosen). Probe 2 showed it already has full access to the package's objects, including rows it doesn't own. One user stores and processes every message, which settles the ownership question ADR 0006 left open: the job can always update what it claims. For: no setup step. Against: it relies on a platform behaviour that isn't documented as a contract, so the integration tests exercise the whole path through a real delivery, and an upgrade that changed it would fail them.
2. **Assign `Event_Ingestion_Processor` to the Automated Process user with a setup script** (the plan before the probe). Against: the assignment changes nothing, so the script would cost a setup step and tell readers something false.
3. **A dedicated integration user through `PlatformEventSubscriberConfig`.** For: an ordinary, auditable user that holds `Event_Ingestion_Processor`. Against: it names a user, so it can't ship in a package. It's the documented alternative for subscriber orgs that require it; `Event_Ingestion_Processor` is that user's permission set, and every message must then be stored and processed by it.

### How much one trigger run takes

1. **Up to `Intake_Batch_Size__c` events (default 200, at most 2,000) or `Intake_Payload_Budget__c` payload characters (default 3,000,000), whichever comes first, always at least one; then a resume checkpoint** (chosen). For: a run never holds more than the heap allows, the store's bulk-tested size is the default, and both limits are subscriber-tunable in `Ingestion_Setting__mdt`. Against: a burst takes more trigger runs.
2. **Everything the trigger receives.** Against: 2,000 full payloads don't fit in 12 MB.
3. **`PlatformEventSubscriberConfig.batchSize`.** Against: it limits the count but not the payload size, and can't be unit-tested.

### Failures while storing

1. **Throw `RetryableException` on every failure, through all 9 retries; one CRITICAL alert on the last; then let the platform suspend the trigger** (chosen). For: no message is lost. A suspended trigger keeps its events, so once the cause is fixed, resuming it in Setup continues where it stopped. Against: a failure that never clears stops intake until someone acts, which is why the last retry alerts.
2. **Give up after 3 retries and log the batch, as apex-platform-logging's log persistence does.** Against: that is right for logs, but here it drops messages.
3. **Catch and continue.** Against: the run's events are gone.

A message the store rejects (ADR 0003) is a different case: rejection is final, so it's logged at WARN by its key (or the event's UUID when it has no key) and not retried. The error text isn't logged, because it can quote the payload.

### Publish behaviour

1. **Publish After Commit** (chosen). For: an Apex producer whose transaction rolls back sends nothing, so the store never holds a message about a change that didn't happen. Against: a producer that wants the message even on rollback can't have it.
2. **Publish Immediately**, as apex-platform-logging's log events use. Right for logs, which must survive a rollback; wrong for business messages.

## Decision

Producers publish `Inbound_Message_Event__e`, which needs the `Event_Ingestion_Publisher` permission set (`EventBus.publish` checks Create on the event). `InboundMessageEventTrigger` calls apex-core-lib's `TriggerDispatcher`, which builds `InboundMessageEventsDomain` through `DI_Binding.Inbound_Message_Events_Domain`. The domain takes events within the intake limits, appends them through `IMessageStore`, calls `MessageProcessing.enqueue()` when at least one was new, and sets a resume checkpoint when it left events behind. Any failure while storing or enqueueing throws `RetryableException`. The Automated Process user stores and processes everything, with no permission set.

## Consequences

- Limits per trigger run: 1 DML statement and at most 1 SOQL query (the store), and 1 Queueable. Bulk-tested at 200 events through a real delivery, and unit-tested at 200.
- A `Trigger_Setting__mdt` row for `Inbound_Message_Event__e` switches intake off without a deploy. Events published while it's off are not stored. To pause intake without losing messages, suspend the trigger in Setup → Platform Events instead.
- Alert sinks called on the last retry run in a transaction that is then rolled back, so a sink must publish an event or call out rather than write records. apex-platform-logging's Slack sink calls out.
- The ownership limit in ADR 0006 no longer applies while messages arrive through this event. It still applies to Apex producers that call `IMessageStore.append` as another user: those messages must be processed by the same user, or that user must be the integration user from option 3.
- Revisit if a release note changes the Automated Process user's access: the integration tests that publish and deliver real events would fail first.
- Rollback posture: suspend `InboundMessageEventTrigger` in Setup (events are kept for 72 hours), or switch it off with `Trigger_Setting__mdt` (events are dropped).
