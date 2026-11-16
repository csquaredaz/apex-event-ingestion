# ADR 0002: Store every inbound message in a custom object, `Inbound_Message__c`

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Chad Countryman

## Context

Messages arrive at least once (the problem statement in the README). To be idempotent and recoverable, the package needs a durable record of every message: what arrived, its key, where it is in processing, how many attempts it has had and why it last failed. Later features read and write that record: dispatch (ADR 0004), Finalizer recovery (ADR 0006), Platform Event intake (ADR 0007), Claim Check (ADR 0008) and the stall sweeper (ADR 0009).

Constraints:

1. The record has to support a database-enforced uniqueness check, because two transactions can receive the same message at the same moment.
2. Processing claims rows, updates their status and retries them, so the store needs row-level updates, indexed filters and `FOR UPDATE`.
3. Operators need to see failed and dead messages in standard UI and reports, with no custom tooling.
4. Free only: no external database, queue or SaaS.

## Options

1. **A custom object, `Inbound_Message__c`** (chosen). For: unique, case-sensitive external Id fields, so the database rejects a second copy; full DML, `FOR UPDATE` and indexed SOQL; list views, reports and permission sets come free. Against: it uses data storage (about 2 KB a row; a scratch org has 500 MB), so a production install needs retention (out of scope for 1.0.0; documented with the stall sweeper in ADR 0009). The payload field is capped at 131,072 characters, which is why Claim Check exists (ADR 0008).
2. **A Big Object.** For: very large volumes at low storage cost. Against: no update in place, no `FOR UPDATE`, only the index fields can be filtered, and no triggers. A status lifecycle doesn't fit.
3. **No store: process straight from the Platform Event, relying on replay.** For: no storage. Against: the event bus keeps events for 72 hours and offers no uniqueness, no status, no attempt count and nothing an operator can query. A failed job loses the messages it had claimed, which is the problem this repo solves.

## Decision

Option 1: a custom object, because it is the only option with a database-enforced unique key and a mutable lifecycle.

The object:

- **Status** (`Status__c`, a restricted picklist): `Received → Processed`, or `Failed` (will retry at `Next_Attempt_At__c`) and then `Dead` (out of attempts). The first version also had `Processing`; ADR 0006 removed it (amended 2026-11-15). `MessageStatuses` holds the values as constants.
- **Producer fields**, copied from the message on append: `Source__c`, `External_Message_Id__c`, `Message_Type__c`, `Payload__c`, `Payload_Ref__c` (a claim check, ADR 0008; amended 2026-11-16), `Correlation_Id__c`, `Occurred_At__c`.
- **`Payload_Size__c`**, set by the store from the inline payload or the claimed file, so the processor job can keep one job within the heap (ADR 0008; amended 2026-11-16).
- **Lifecycle fields**, owned by the package: `Status__c`, `Attempts__c`, `Next_Attempt_At__c`, `Last_Error__c`, `Processed_At__c`. `MessageStore.append` never copies them from the caller, so a producer can't inject a message as already `Processed`. `Locked_Until__c` was removed with `Processing`: a processor job claims rows with a row lock instead (ADR 0006).
- **Sharing:** OWD Private. Two permission sets:
  - `Event_Ingestion_Processor`: create, read and edit, plus View All, for the user that runs ingestion. It has no Modify All, because Modify All also requires Delete, and the package never deletes messages. How the stall sweeper updates rows it doesn't own is decided in PR 7.
  - `Event_Ingestion_Viewer`: read only, plus View All, for operators.
- **Access:** reads go through `InboundMessagesSelector` (apex-core-lib's `SObjectSelector`, user mode). The standard field list leaves out `Payload__c`, which can be up to 131,072 characters.

## Consequences

- Every query and write runs in user mode, so the ingestion user must hold `Event_Ingestion_Processor`. Without Create, `IMessageStore.append` throws `MessageStoreException` instead of rejecting every message (ADR 0003), so a missing permission set surfaces as a retryable failure, not as lost messages.
- The integration tests run as Minimum Access users with and without each permission set, because an admin gets no field permissions on newly deployed package fields.
- Retention and archiving are left to the subscriber org for now. Revisit before 1.0.0 if the stall sweeper's ADR (0009) needs a purge path.
- Rollback: the object and permission sets are additive metadata. Uninstalling the package deletes the object and its rows, so the README will tell operators to export first.
