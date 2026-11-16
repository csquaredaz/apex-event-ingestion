# Changelog

Each `## X.Y.Z` section is added to the GitHub release notes for tag `vX.Y.Z` by `release.yml`. A tag without a section fails before the package version is built, so write the section in the PR that bumps `versionNumber`.

## 1.0.0

The first release: idempotent, recoverable inbound message ingestion on apex-core-lib `1.1.0-1`. Install apex-core-lib first.

### Added

- **Message store** (ADR 0002, 0003): `Inbound_Message__c` with the lifecycle `Received → Processed`, or `Failed` and then `Dead`. `IMessageStore.append` stores each message once on the producer's key `Source:ExternalId` (a unique, case-sensitive field) and returns `ACCEPTED`, `DUPLICATE` or `REJECTED` per message; it throws `MessageStoreException` when the user can't create messages.
- **Dispatch** (ADR 0004, 0005): bulk Command handlers (`IMessageHandler`, `InboundMessage`, `HandlerResult`) routed by `Message_Route__mdt`; several routes for one type form a Composite where the worst result wins; each handler call is guarded by a savepoint. No ordering guarantee: handlers skip stale changes with `InboundMessage.isOlderThan`.
- **Processing and recovery** (ADR 0006): `MessageProcessing.enqueue()` queues one `MessageProcessorJob`, which claims a batch with a `FOR UPDATE` row lock and records outcomes in the same transaction. `MessageProcessorFinalizer` recovers a failed job's messages with exponential backoff (or `Dead`), alerts, and decides the next run. Limits in `Ingestion_Setting__mdt.Default`.
- **Intake** (ADR 0007): the high-volume Platform Event `Inbound_Message_Event__e` (Publish After Commit), stored by the Automated Process user through a checkpointed trigger that retries every failure and alerts on the last retry. Producers need `Event_Ingestion_Publisher`.
- **Claim Check** (ADR 0008): a payload over 131,072 characters travels as a `ContentVersion` Id in `Payload_Ref__c`, accepted only from the user who uploaded that version and within `Claim_Max_Bytes__c`; each job dispatches within `Dispatch_Payload_Budget__c`.
- **Stall sweeper** (ADR 0009): `StallSweeperSchedulable` on four 15-minute schedules wakes processing through `Processor_Wake_Event__e`, so the job runs as the Automated Process user, and raises a WARNING for messages due over 30 minutes. Scheduling is a setup step: assign `Event_Ingestion_Sweeper`, then run `scripts/schedule-stall-sweeper.apex`.
- Permission sets: `Event_Ingestion_Processor`, `Event_Ingestion_Viewer`, `Event_Ingestion_Publisher`, `Event_Ingestion_Sweeper`.
- An unpackaged `example/` integration (two handlers on `order.status_changed`) and an end-to-end test, not part of the package.

### Known limits

- Handlers can't make synchronous callouts (the savepoint guard); enqueue a Queueable instead.
- A Finalizer whose own recovery fails leaves the messages without an attempt counted; the stall sweeper alerts on them (ADR 0006).
- Retention of stored messages and claimed files is left to the subscriber org. Uninstalling the package deletes `Inbound_Message__c` and its rows, so export them first.

### Rollback

Uninstall the package (apex-core-lib is unaffected), after exporting stored messages. To stop work without uninstalling: deactivate routes, suspend `InboundMessageEventTrigger` in Setup (events are kept for 72 hours), and delete the four "aei stall sweeper" scheduled jobs.
